# Infrastructure for Yandex Data Processing and Yandex Object Storage with init action script
#
# RU: https://yandex.cloud/ru/docs/tutorials/dataplatform/data-processing-init-actions-geesefs
# EN: https://yandex.cloud/en/docs/tutorials/dataplatform/data-processing-init-actions-geesefs
#
# Specify the following settings:
locals {

  # The following settings are to be specified by the user. Change them as you wish.

  # Network settings
  dp_network_name = "" # Network name  
  dp_subnet_name  = "" # Subnet name  

  # Security group settings:
  dp_sg_name = "" # Security group name  

  # Service account settings:  
  dp_sa_folder_id = "" # ID of the folder for the service account
  dp_sa_name      = "" # Name of the service account  

  # Object Storage settings
  dp_bucket_name = "" # Name of the Yandex Object Storage bucket

  # Data Proc settings
  dataproc_name = "" # Name of the Yandex Data Processing cluster  
  ssh_path      = "" # Path to the public SSH key file.

  # This setting sets the order of resource creation
  create_cluster = 0 # Set this setting to 1 to enable creation of the Yandex Data Processing infrastructure and cluster.

  # The following settings are predefined. Change them only if necessary.

  # Route table and gateway settings
  nat_gateway_name       = "dp-gateway"   # Name of the NAT Gateway
  nat_rt_name            = "myroutetable" # Name of the route table
  nat_destination_prefix = "0.0.0.0/0"    # Route table destination prefix for NAT

  # Data Proc settings
  dataproc_version = "2.0"                                # Version of the Yandex Data Processing cluster.
  masternode_name  = "mastersubcluster"                   # Name of the Master node in the Yandex Data Processing cluster.
  services         = ["SPARK", "TEZ", "YARN"]             # List of components to use in the Yandex Data Processing cluster.
  computenode_name = "computesubcluster"                  # Name of the Compute node in the Yandex Data Processing cluster.
  bucket           = yandex_storage_bucket.data-bucket.id # ID of the bucket to use in the Yandex Data Processing cluster.
}

resource "yandex_vpc_network" "mynet" {
  description = "Network for the Yandex Data Processing cluster"
  name        = local.dp_network_name
}

resource "yandex_vpc_subnet" "mysubnet" {
  description    = "Subnet for the Yandex Data Processing cluster"
  name           = local.dp_subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.mynet.id
  v4_cidr_blocks = ["10.1.0.0/16"]
  route_table_id = yandex_vpc_route_table.route-table-for-nat.id
}

resource "yandex_vpc_security_group" "my-sg" {
  description = "Security group for theYandex Data Processing cluster"
  name        = local.dp_sg_name
  network_id  = yandex_vpc_network.mynet.id

  ingress {
    description    = "This rule allows all incoming HTTPS traffic"
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  ingress {
    description    = "This rule allows to connect to the Yandex Data Processing cluster host via SSH"
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }

  egress {
    description    = "This rule allows all outgoing HTTPS traffic"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description       = "This rule allows any incoming traffic within the security group"
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
  }

  egress {
    description       = "This rule allows any outgoing traffic within the security group"
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
  }

  egress {
    description    = "This rule allows outgoing traffic to NTP servers for time synchronization"
    protocol       = "UDP"
    port           = 123
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_vpc_gateway" "nat-gateway" {
  name = local.nat_gateway_name
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "route-table-for-nat" {
  name       = local.nat_rt_name
  network_id = yandex_vpc_network.mynet.id

  static_route {
    destination_prefix = local.nat_destination_prefix
    gateway_id         = yandex_vpc_gateway.nat-gateway.id
  }
}

resource "yandex_iam_service_account" "data-proc-sa" {
  description = "Service account for the Yandex Data Processing cluster and the Yandex Object Storage bucket"
  name        = local.dp_sa_name
}

resource "yandex_resourcemanager_folder_iam_member" "dataproc-agent" {
  folder_id = local.dp_sa_folder_id
  role      = "dataproc.agent"
  member    = "serviceAccount:${yandex_iam_service_account.data-proc-sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "dataproc-provisioner" {
  folder_id = local.dp_sa_folder_id
  role      = "dataproc.provisioner"
  member    = "serviceAccount:${yandex_iam_service_account.data-proc-sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa-editor" {
  folder_id = local.dp_sa_folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.data-proc-sa.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  description        = "Static key for managing the Yandex Object Storage bucket"
  service_account_id = yandex_iam_service_account.data-proc-sa.id
}

resource "yandex_storage_bucket" "data-bucket" {
  bucket     = local.dp_bucket_name
  max_size   = 10 # GB
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  depends_on = [
    yandex_resourcemanager_folder_iam_member.sa-editor
  ]
}

resource "yandex_dataproc_cluster" "data_cluster" {
  description        = "Yandex Data Processing cluster"
  name               = local.dataproc_name
  bucket             = local.bucket
  count              = local.create_cluster
  service_account_id = yandex_iam_service_account.data-proc-sa.id
  zone_id            = "ru-central1-a"
  security_group_ids = [yandex_vpc_security_group.my-sg.id]

  cluster_config {
    version_id = local.dataproc_version
    hadoop {
      services = local.services
      ssh_public_keys = [
        file(local.ssh_path)
      ]
      initialization_action {
        uri  = "s3a://${local.dp_bucket_name}/geesefs_mount.sh"
        args = [local.dp_bucket_name, "/mnt/test"]
      }
    }

    subcluster_spec {
      name = local.masternode_name
      role = "MASTERNODE"
      resources {
        resource_preset_id = "s2.micro" # 2 CPU, 8 GB RAM
        disk_type_id       = "network-hdd"
        disk_size          = 20 # GB
      }
      subnet_id        = yandex_vpc_subnet.mysubnet.id
      hosts_count      = 1
      assign_public_ip = true
    }

    subcluster_spec {
      name = local.computenode_name
      role = "COMPUTENODE"
      resources {
        resource_preset_id = "s2.micro" # 2 CPU, 8 GB RAM
        disk_type_id       = "network-hdd"
        disk_size          = 20 # GB
      }
      subnet_id        = yandex_vpc_subnet.mysubnet.id
      hosts_count      = 1
      assign_public_ip = true
    }
  }
  depends_on = [
    yandex_resourcemanager_folder_iam_member.dataproc-agent,
    yandex_resourcemanager_folder_iam_member.dataproc-provisioner,
  ]
}
