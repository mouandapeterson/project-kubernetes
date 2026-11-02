# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Pour activer zsh, définir ENABLE_ZSH à "true" avant "vagrant up" :
#   + Windows (PowerShell) => $env:ENABLE_ZSH="true"
#   + Linux / macOS        => export ENABLE_ZSH="true"
 
# =============================================================================
#  Configuration : c'est le SEUL endroit à modifier
# =============================================================================
# Système de la VM : "ubuntu" (Ubuntu 24.04) ou "rocky" (Rocky Linux 9)
OS = "rocky"
 
BOXES = {
  "ubuntu" => "bento/ubuntu-24.04",
  "rocky"  => "bento/rockylinux-9",
}
 
# Le dossier projet est synchronisé par rsync, dans un seul sens : Windows -> VM.
#   + rsync doit être dans le PATH Windows (ex. Cygwin)
#   + lancer "vagrant rsync-auto" pendant le travail
#   + ne pas créer/modifier de fichiers du projet dans la VM : ils seraient
#     écrasés ou supprimés à la synchronisation suivante
# Aucun dossier partagé VirtualBox : les Guest Additions ne sont pas utilisées.
 
BOX_VERSION = nil            # ex : "202510.26.0" (voir "vagrant box list"), nil = dernière
VM_IP       = "192.168.56.10"
VM_CPUS     = 4
VM_MEMORY   = 9216
 
SYNC_HOST   = "."                                  # dossier Windows (celui du Vagrantfile)
SYNC_GUEST  = "/home/vagrant/project-kubernetes"   # chemin dans la VM
NODE_PATH   = "/project-kubernetes"                # chemin vu par les pods (hostPath)
 
VERSIONS = {
  "MINIKUBE_VERSION"   => "v1.37.0",
  "KUBERNETES_VERSION" => "1.34.0",
  "MINIKUBE_CPUS"      => "4",
  "MINIKUBE_MEMORY"    => "4096",
  "MINIKUBE_PORTS"     => "30000-30010:30000-30010",
  "MINIKUBE_MOUNT"     => "#{SYNC_GUEST}:#{NODE_PATH}",
}
# =============================================================================
 
abort "OS inconnu : #{OS} (valeurs possibles : #{BOXES.keys.join(', ')})" unless BOXES.key?(OS)
BOX = BOXES[OS]
 
Vagrant.configure("2") do |config|
 
  # Ne pas laisser vagrant-vbguest toucher aux Guest Additions (plugin abandonné)
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
    config.vbguest.no_remote   = true
  end
 
  config.vm.define "minikube" do |minikube|
    minikube.vm.box          = BOX
    minikube.vm.box_version  = BOX_VERSION if BOX_VERSION
    minikube.vm.hostname     = "minikube"
    minikube.vm.boot_timeout = 600
 
    # VirtualBox 7 n'autorise par défaut que la plage 192.168.56.0/21
    minikube.vm.network "private_network", ip: VM_IP
 
    # Pas de dossier /vagrant par défaut
    minikube.vm.synced_folder ".", "/vagrant", disabled: true
 
    # Dossier projet : synchronisation à sens unique Windows -> VM
    minikube.vm.synced_folder SYNC_HOST, SYNC_GUEST,
      type:           "rsync",
      rsync__exclude: [".git/", ".vagrant/"],
      # --chmod : évite les droits incohérents hérités de NTFS via Cygwin
      rsync__args:    ["--verbose", "--archive", "--delete", "-z", "--copy-links",
                       "--chmod=D775,F664"]
 
    minikube.vm.provider "virtualbox" do |v|
      v.name   = "minikube"
      v.cpus   = VM_CPUS
      v.memory = VM_MEMORY
      # DNS de la VM résolu par Windows : plus fiable derrière une box, un VPN ou un proxy
      v.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end
 
    minikube.vm.provision "shell",
      path: "install_minikube.sh",
      env:  VERSIONS.merge(
        "ENABLE_ZSH" => ENV.fetch("ENABLE_ZSH", "false"),
        "VM_IP"      => VM_IP
      )
 
    # À chaque "vagrant up" / "vagrant reload" : le dossier projet vient d'être
    # synchronisé, on (re)lance le montage du projet dans le nœud minikube
    minikube.vm.provision "shell", run: "always", name: "minikube-mount",
      inline: "systemctl list-unit-files minikube-mount.service >/dev/null 2>&1 && systemctl restart --no-block minikube-mount.service || true"
  end
end
