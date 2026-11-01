output "instance_public_ip" {
  description = "Public IP address of the EC2 cluster node"
  value       = aws_instance.k3s_node.public_ip
}

# Automatically creates the Ansible inventory file upon completion
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/inventory.tmpl", {
    ip          = aws_instance.k3s_node.public_ip,
    ssh_keyfile = "${path.module}/id_rsa"
  })
  filename = "${path.module}/../ansible/inventory.ini"
}