terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
    }
  }
}

data "hcloud_server_type" "server_type" {
  name = var.hcloud_server_type_name
}

data "hcloud_image" "image" {
  name = var.hcloud_image_name
}

data "hcloud_location" "location" {
  name = var.hcloud_location_name
}

data "hcloud_ssh_key" "existing_ssh_key" {
  name = var.ssh_key_name
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_network" "network1" {
  name     = "${var.project_name}-network"
  ip_range = var.network_ip_range
}

resource "hcloud_network_subnet" "subnet1" {
  network_id   = hcloud_network.network1.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = var.subnet_ip_range
}

resource "hcloud_firewall" "firewall1" {
  name = "${var.project_name}-firewall"

  dynamic "rule" {
    for_each = var.firewall_rules

    content {
      direction = "in"  # Assuming all rules are inbound
      protocol  = rule.value.protocol
      port      = rule.value.port
      source_ips = rule.value.source_ips
    }
  }
}

resource "hcloud_volume" "volume1" {
  count      = var.create_volume ? 1 : 0
  name       = "${var.project_name}-volume"
  size       = 10 # Size in GB
  format     = "ext4"
  automount  = true
  server_id  = hcloud_server.master.id
}

resource "hcloud_server" "master" {
  name        = "${var.project_name}-1"
  server_type = data.hcloud_server_type.server_type.name
  image       = data.hcloud_image.image.name
  location    = data.hcloud_location.location.name
  ssh_keys    = [data.hcloud_ssh_key.existing_ssh_key.id]
  firewall_ids = [hcloud_firewall.firewall1.id]

  user_data = <<-EOT
    #cloud-config

    packages:
        - ca-certificates
        - curl
        - gnupg

    package_update: true
    package_upgrade: true

    runcmd:
        - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        - sudo chmod a+r /etc/apt/keyrings/docker.gpg
        - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        - apt-get update
        - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose
        - systemctl enable docker
        - reboot
  EOT

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file(var.ssh_priv_key_path)
    host        = self.ipv4_address
  }

  provisioner "file" {
    source      = "stacks/portainer/portainer-agent-stack.yml"
    destination = "/tmp/portainer-agent-stack.yml"
  }

  provisioner "remote-exec" {
    inline = [
      "docker swarm init --advertise-addr ${var.server_network_ip}",
      "docker network create --driver overlay monitoring",
      "docker stack deploy -c /tmp/portainer-agent-stack.yml portainer",
    ]
  }
}

resource "hcloud_server_network" "server_network" {
  server_id  = hcloud_server.master.id
  network_id = hcloud_network.network1.id
  ip         = var.server_network_ip
}

output "master_public_ip" {
  value = hcloud_server.master.ipv4_address
  description = "The public IP address of the master server."
}

output "portainer_address" {
  value = "https://${hcloud_server.master.ipv4_address}:9443"
  description = "The URL to access the Portainer service running on master."
}