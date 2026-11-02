#!/bin/bash
# =============================================================================
#  Installation de Minikube (driver docker) sur une VM Vagrant / VirtualBox
#  Cibles : Ubuntu 22.04/24.04, Debian 12, Rocky Linux / AlmaLinux 9
#           (CentOS 7 toléré, sans zsh)
#
#  Toutes les valeurs peuvent être surchargées par des variables
#  d'environnement (transmises par le Vagrantfile).
#  Le script est idempotent : "vagrant provision" peut être relancé sans risque.
# =============================================================================
 
set -euo pipefail
 
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi
 
# -----------------------------------------------------------------------------
# Variables (valeurs par défaut = combinaison testée)
# -----------------------------------------------------------------------------
MINIKUBE_VERSION="${MINIKUBE_VERSION:-v1.37.0}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.34.0}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-2}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-3072}"
# Ports NodePort exposés sur l'IP de la VM (vide = aucun)
MINIKUBE_PORTS="${MINIKUBE_PORTS:-30000-30010:30000-30010}"
# Dossier de la VM monté dans le nœud : "chemin_vm:chemin_noeud" (vide = aucun)
MINIKUBE_MOUNT="${MINIKUBE_MOUNT:-}"
ENABLE_ZSH="${ENABLE_ZSH:-false}"
VAGRANT_USER="${VAGRANT_USER:-vagrant}"
# IP privée de la VM (transmise par le Vagrantfile, détectée sinon)
VM_IP="${VM_IP:-}"
 
KUBERNETES_MINOR="v${KUBERNETES_VERSION%.*}"     # ex : 1.34.0 -> v1.34
VAGRANT_HOME="$(getent passwd "$VAGRANT_USER" | cut -d: -f6)"
export PATH="$PATH:/usr/local/bin"
# apt : aucune question interactive, aucun redémarrage de service demandé
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
 
log()      { echo -e "\n\033[1;34m==> $*\033[0m"; }
warn()     { echo -e "\033[1;33m[ATTENTION] $*\033[0m"; }
die()      { echo -e "\033[1;31m[ERREUR] $*\033[0m" >&2; exit 1; }
add_line() { grep -qxF "$1" "$2" 2>/dev/null || echo "$1" >> "$2"; }
as_user()  { su - "$VAGRANT_USER" -c "$1"; }
 
# Téléchargement robuste : download <fichier_destination> <url1> [url2 ...]
# 5 tentatives, en alternant entre les URL fournies (miroirs de secours)
download() {
  local dest="$1"; shift
  local attempt url
  for attempt in 1 2 3 4 5; do
    for url in "$@"; do
      if curl -fSL --connect-timeout 20 --retry 3 --retry-delay 5 -o "$dest" "$url"; then
        return 0
      fi
      warn "Échec du téléchargement depuis ${url} (tentative ${attempt}/5)"
      rm -f "$dest"
    done
    sleep $((attempt * 5))
  done
  echo "Impossible de télécharger ${dest} après 5 tentatives." >&2
  return 1
}
 
# -----------------------------------------------------------------------------
# Détection du système
# -----------------------------------------------------------------------------
source /etc/os-release
OS_MAJOR="${VERSION_ID%%.*}"
if command -v apt-get >/dev/null 2>&1; then
  FAMILY="debian"
elif command -v yum >/dev/null 2>&1; then
  FAMILY="rhel"
else
  die "Système non pris en charge : ${PRETTY_NAME}"
fi
 
pkg_install() {
  if [[ "$FAMILY" == "debian" ]]; then
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$@"
  else
    yum install -y "$@"
  fi
}
 
log "Système : ${PRETTY_NAME} (${FAMILY}) | Minikube ${MINIKUBE_VERSION} | Kubernetes v${KUBERNETES_VERSION}"
 
# -----------------------------------------------------------------------------
# 1. Dépôts et paquets de base
# -----------------------------------------------------------------------------
if [[ "$FAMILY" == "rhel" ]]; then
  if [[ "$ID" == "centos" && "$OS_MAJOR" == "7" ]]; then
    warn "CentOS 7 est en fin de vie : dépôts basculés vers vault.centos.org"
    sed -i -e 's/mirror.centos.org/vault.centos.org/g' \
           -e 's/^#.*baseurl=http/baseurl=http/g' \
           -e 's/^mirrorlist=http/#mirrorlist=http/g' \
           /etc/yum.repos.d/CentOS-*.repo
  fi
 
  log "Mise à jour du système et paquets de base"
  yum -y update
  pkg_install yum-utils git tar curl bash-completion
else
  log "Mise à jour du système et paquets de base"
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
  pkg_install ca-certificates curl gnupg git tar bash-completion
fi
 
# -----------------------------------------------------------------------------
# 2. Réglages système (environnement de lab)
# -----------------------------------------------------------------------------
if [[ "$FAMILY" == "rhel" ]]; then
  log "SELinux en permissive et firewalld désactivé"
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    setenforce 0
  fi
  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
  systemctl disable --now firewalld 2>/dev/null || true
else
  log "Pare-feu ufw désactivé"
  if command -v ufw >/dev/null 2>&1; then
    ufw disable || true
  fi
fi
 
# -----------------------------------------------------------------------------
# 3. Docker
# -----------------------------------------------------------------------------
log "Installation de Docker"
if [[ "$FAMILY" == "rhel" ]]; then
  yum remove -y docker docker-client docker-client-latest docker-common docker-latest \
    docker-latest-logrotate docker-logrotate docker-engine podman buildah || true
  [[ -f /etc/yum.repos.d/docker-ce.repo ]] || \
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
else
  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 \
    podman-docker containerd runc 2>/dev/null || true
  install -m 0755 -d /etc/apt/keyrings
  download /etc/apt/keyrings/docker.asc "https://download.docker.com/linux/${ID}/gpg"
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
fi
pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "$VAGRANT_USER"
 
# -----------------------------------------------------------------------------
# 4. Minikube
# -----------------------------------------------------------------------------
INSTALLED_MK="$(minikube version --short 2>/dev/null || true)"
if [[ "$INSTALLED_MK" != "$MINIKUBE_VERSION" ]]; then
  log "Installation de Minikube ${MINIKUBE_VERSION}"
  MK_GCS="https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}"
  MK_GITHUB="https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}"
  download /tmp/minikube        "${MK_GCS}/minikube-linux-amd64"        "${MK_GITHUB}/minikube-linux-amd64"
  download /tmp/minikube.sha256 "${MK_GCS}/minikube-linux-amd64.sha256" "${MK_GITHUB}/minikube-linux-amd64.sha256"
 
  # Vérification de l'intégrité (détecte un fichier tronqué ou corrompu)
  echo "$(awk '{print $1}' /tmp/minikube.sha256)  /tmp/minikube" | sha256sum -c -
  install -m 0755 /tmp/minikube /usr/local/bin/minikube
  rm -f /tmp/minikube /tmp/minikube.sha256
else
  log "Minikube ${MINIKUBE_VERSION} déjà installé"
fi
 
# -----------------------------------------------------------------------------
# 5. kubectl (même version mineure que le cluster)
# -----------------------------------------------------------------------------
log "Installation de kubectl ${KUBERNETES_VERSION}"
if [[ "$FAMILY" == "rhel" ]]; then
  cat > /etc/yum.repos.d/kubernetes.repo <<REPO
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
REPO
  yum install -y "kubectl-${KUBERNETES_VERSION}" --disableexcludes=kubernetes
else
  install -m 0755 -d /etc/apt/keyrings
  download /tmp/kubernetes-release.key "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key"
  gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg /tmp/kubernetes-release.key
  rm -f /tmp/kubernetes-release.key
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update
  # Version exacte du paquet (ex : 1.34.0-1.1)
  KUBECTL_PKG="$(apt-cache madison kubectl | awk -v v="${KUBERNETES_VERSION}-" '!found && index($3, v) == 1 {print $3; found = 1}')"
  [[ -n "$KUBECTL_PKG" ]] || die "kubectl ${KUBERNETES_VERSION} introuvable dans le dépôt ${KUBERNETES_MINOR}"
  apt-mark unhold kubectl >/dev/null 2>&1 || true
  pkg_install --allow-downgrades "kubectl=${KUBECTL_PKG}"
  apt-mark hold kubectl
fi
 
# -----------------------------------------------------------------------------
# 6. Démarrage du cluster (driver docker : jamais en root)
# -----------------------------------------------------------------------------
if as_user "minikube status" >/dev/null 2>&1; then
  log "Le cluster minikube tourne déjà"
else
  log "Démarrage du cluster minikube"
  START_OPTS="--driver=docker --kubernetes-version=v${KUBERNETES_VERSION}"
  START_OPTS+=" --cpus=${MINIKUBE_CPUS} --memory=${MINIKUBE_MEMORY}"
  START_OPTS+=" --listen-address=0.0.0.0"
  if [[ -n "$MINIKUBE_PORTS" ]]; then
    START_OPTS+=" --ports=${MINIKUBE_PORTS}"
  fi
  # minikube télécharge ~1 Go d'images : on réessaie en cas de coupure réseau
  for attempt in 1 2 3; do
    as_user "minikube start ${START_OPTS}" && break
    if [[ $attempt -eq 3 ]]; then
      die "Échec du démarrage de minikube après 3 tentatives."
    fi
    warn "Échec de minikube start (tentative ${attempt}/3), nouvel essai dans 15 s"
    sleep 15
  done
fi
 
# Redémarrage automatique du cluster quand la VM redémarre
log "Service systemd de démarrage automatique"
cat > /etc/systemd/system/minikube.service <<UNIT
[Unit]
Description=Minikube (cluster Kubernetes local)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target
 
[Service]
Type=oneshot
RemainAfterExit=yes
User=${VAGRANT_USER}
Group=${VAGRANT_USER}
ExecStart=/usr/local/bin/minikube start
ExecStop=/usr/local/bin/minikube stop
TimeoutStartSec=600
 
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable minikube.service
 
# Montage du dossier projet dans le nœud minikube (service permanent)
if [[ -n "$MINIKUBE_MOUNT" ]]; then
  log "Montage ${MINIKUBE_MOUNT} dans le nœud minikube"
  MOUNT_SRC="${MINIKUBE_MOUNT%%:*}"
  install -d -o "$VAGRANT_USER" -g "$VAGRANT_USER" "$MOUNT_SRC"
  cat > /etc/systemd/system/minikube-mount.service <<UNIT
[Unit]
Description=Montage ${MINIKUBE_MOUNT} dans le nœud minikube
After=minikube.service
Requires=minikube.service
 
[Service]
Type=simple
User=${VAGRANT_USER}
Group=${VAGRANT_USER}
ExecStart=/usr/local/bin/minikube mount ${MINIKUBE_MOUNT}
Restart=on-failure
RestartSec=10
 
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable minikube-mount.service
  systemctl restart minikube-mount.service
else
  systemctl disable --now minikube-mount.service 2>/dev/null || true
  rm -f /etc/systemd/system/minikube-mount.service
  systemctl daemon-reload
fi
 
# -----------------------------------------------------------------------------
# 7. Confort shell
# -----------------------------------------------------------------------------
log "Complétion et alias bash"
BASHRC="${VAGRANT_HOME}/.bashrc"
add_line 'source <(kubectl completion bash)'  "$BASHRC"
add_line 'source <(minikube completion bash)' "$BASHRC"
add_line 'alias k=kubectl'                    "$BASHRC"
add_line 'complete -F __start_kubectl k'      "$BASHRC"
chown "${VAGRANT_USER}:${VAGRANT_USER}" "$BASHRC"
 
if [[ "$ENABLE_ZSH" == "true" ]]; then
  if [[ "$FAMILY" == "rhel" && "$OS_MAJOR" == "7" ]]; then
    warn "Oh My Zsh demande zsh >= 5.0.8 (CentOS 7 fournit 5.0.2) : zsh ignoré"
  else
    log "Installation de zsh et Oh My Zsh"
    pkg_install zsh
    usermod -s "$(command -v zsh)" "$VAGRANT_USER"
    if [[ ! -d "${VAGRANT_HOME}/.oh-my-zsh" ]]; then
      as_user 'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
    fi
    PLUGIN_DIR="${VAGRANT_HOME}/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"
    if [[ ! -d "$PLUGIN_DIR" ]]; then
      as_user "git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git ${PLUGIN_DIR}"
    fi
    ZSHRC="${VAGRANT_HOME}/.zshrc"
    sed -i 's/^plugins=(.*/plugins=(git docker docker-compose helm kubectl kubectx minikube colored-man-pages aliases copyfile copypath dotenv zsh-syntax-highlighting jsontools)/' "$ZSHRC"
    sed -i 's/^ZSH_THEME=.*/ZSH_THEME="agnoster"/' "$ZSHRC"
    chown "${VAGRANT_USER}:${VAGRANT_USER}" "$ZSHRC"
  fi
fi
 
# -----------------------------------------------------------------------------
# 8. Vérification finale
# -----------------------------------------------------------------------------
log "Vérification du cluster"
if ! as_user "kubectl wait --for=condition=Ready node --all --timeout=300s" >/dev/null; then
  die "Le nœud Kubernetes n'est pas prêt. Diagnostic : vagrant ssh puis 'minikube logs'"
fi
 
if [[ -z "$VM_IP" ]]; then
  VM_IP="$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\.56\./ {split($4, a, "/"); print a[1]}' | head -n1 || true)"
fi
 
as_user "kubectl get nodes -o wide"
echo -e "\nTout est OK, minikube est prêt."
echo "IP de la VM : ${VM_IP:-inconnue}"
if [[ -n "$MINIKUBE_PORTS" ]]; then
  echo "Services NodePort accessibles depuis Windows : http://${VM_IP:-<ip_vm>}:<port> (ports ${MINIKUBE_PORTS%%:*})"
fi
echo "Dossier projet synchronisé Windows -> VM : lancez 'vagrant rsync-auto' sous Windows pendant que vous travaillez."
exit 0
