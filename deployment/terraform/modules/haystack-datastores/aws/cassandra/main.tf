// using data-source to find latest cassandra image
data "aws_ami" "haystack-cassandra-base-ami" {
  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "tag:type"
    values = ["haystack-cassandra-base"]
  }

  most_recent = true
}

locals {
  cassandra_ami = "${var.node_image == "" ? data.aws_ami.haystack-cassandra-base-ami.image_id : var.node_image }"
  cassandra_config_yaml_path = "/etc/cassandra/default.conf/cassandra.yaml"
  cassandra_non_seed_node_count = "${var.node_count - 1}"
  cassandra_cname = "${var.haystack_cluster_name}-cassandra"
  cassandra_ssh_user = "ec2-user"
}

module "cassandra-security-groups" {
  source = "security_groups"
  aws_vpc_id= "${var.aws_vpc_id}"
  haystack_cluster_name = "${var.haystack_cluster_name}"
}

data "template_file" "cassandra_seed_user_data" {
  template = "${file("${path.module}/data/seed_node_user_data_sh.tpl")}"

  vars {
    haystack_graphite_host = "${var.graphite_host}"
    haystack_graphite_port = "${var.graphite_port}"
  }
}

// create seed node
resource "aws_instance" "haystack-cassandra-seed-node" {
  ami = "${local.cassandra_ami}"
  instance_type = "${var.node_instance_type}"
  subnet_id = "${var.aws_subnet}"
  vpc_security_group_ids = [ "${module.cassandra-security-groups.nodes_security_group_ids}"]
  key_name = "${var.aws_ssh_key_pair_name}"
  associate_public_ip_address = false
  tags = {
    Product = "Haystack"
    Component = "Cassandra"
    ClusterName = "${var.haystack_cluster_name}"
    Role = "${var.haystack_cluster_name}-cassandra"
    Name = "${var.haystack_cluster_name}-cassandra"
    NodeType = "seed"
  }

  root_block_device = {
    volume_type = "gp2"
    volume_size = "${var.node_volume_size}"
    delete_on_termination = false
  }

  user_data = "${data.template_file.cassandra_seed_user_data.rendered}"
}

data "template_file" "cassandra_non_seed_user_data" {
  template = "${file("${path.module}/data/non_seed_node_user_data_sh.tpl")}"

  vars {
    seed_ip = "${aws_instance.haystack-cassandra-seed-node.private_ip}"
    haystack_graphite_host = "${var.graphite_host}"
    haystack_graphite_port = "${var.graphite_port}"
  }
}

// use seed node ip to create & initialize non-seed nodes
resource "aws_instance" "haystack-cassandra-non-seed-nodes" {
  count = "${local.cassandra_non_seed_node_count}"
  ami = "${local.cassandra_ami}"
  instance_type = "${var.node_instance_type}"
  subnet_id = "${var.aws_subnet}"
  vpc_security_group_ids = [ "${module.cassandra-security-groups.nodes_security_group_ids}"]
  associate_public_ip_address = false
  key_name = "${var.aws_ssh_key_pair_name}"

  tags {
    Product = "Haystack"
    Component = "Cassandra"
    ClusterName = "${var.haystack_cluster_name}"
    Role = "${var.haystack_cluster_name}-cassandra"
    Name = "${var.haystack_cluster_name}-cassandra-${count.index}"
    Seed = "${aws_instance.haystack-cassandra-seed-node.private_ip}"
    NodeType = "non-seed"
  }

  root_block_device = {
    volume_type = "gp2"
    volume_size = "${var.node_volume_size}"
    delete_on_termination = false
  }

  user_data = "${data.template_file.cassandra_non_seed_user_data.rendered}"
}

// create cname for newly created cassandra cluster
resource "aws_route53_record" "haystack-cassandra-cname" {
  zone_id = "${var.aws_hosted_zone_id}"
  name    = "${local.cassandra_cname}"
  type    = "A"
  ttl     = "300"
  records = ["${aws_instance.haystack-cassandra-seed-node.private_ip}","${aws_instance.haystack-cassandra-non-seed-nodes.*.private_ip}"]
}
