output "instance_id" {
  value = aws_instance.api.id
}

output "elastic_ip" {
  value = aws_eip.api.public_ip
}

output "public_dns" {
  value = aws_eip.api.public_dns
}
