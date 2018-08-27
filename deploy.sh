#!/bin/bash

set -o xtrace

unset GREP_OPTIONS

unset LANG
unset LANGUAGE
LC_ALL=en_US.utf8
export LC_ALL

umask 022

TOP_DIR=$(cd $(dirname "$0") && pwd)
FILES=$TOP_DIR/files

source $TOP_DIR/localrc
source $TOP_DIR/defaultrc
source $TOP_DIR/functions
source $TOP_DIR/lib/functions-common
source $TOP_DIR/lib/systemctl
source $TOP_DIR/lib/sudoers
source $TOP_DIR/lib/mariadb
source $TOP_DIR/lib/placement
source $TOP_DIR/lib/keystone
source $TOP_DIR/lib/rpc_backend
source $TOP_DIR/lib/apache
source $TOP_DIR/lib/glance
source $TOP_DIR/lib/nova
source $TOP_DIR/lib/neutron
source $TOP_DIR/lib/horizon
source $TOP_DIR/inc/ini-config
source $TOP_DIR/lib/neutron_plugins/services/ovs

ENABLE_DEBUG_LOG_LEVEL=$(trueorfalse True ENABLE_DEBUG_LOG_LEVEL)
SYSTEMD_DIR=/etc/systemd/system/
SYSTEMCTL=systemctl
SERVICE_TIMEOUT=${SERVICE_TIMEOUT:-60}

disable_firewalld
disable_selinux

#configure hostname
LOCAL_HOSTNAME=`hostname -s`
if [ -z "`grep ^127.0.0.1 /etc/hosts | grep $LOCAL_HOSTNAME`" ]; then
    sudo sed -i "s/\(^127.0.0.1.*\)/\1 $LOCAL_HOSTNAME/" /etc/hosts
fi

if [ -z "`grep controller$ /etc/hosts |grep controller`" ]; then
    sudo echo "$CONTROLLER_IP controller" >> /etc/hosts
fi

if [[ `echo $PYTHONPATH` == "" || "`echo $PYTHONPATH| grep $DEST_BASE/lib`" == "" ]]; then
    export PYTHONPATH="$DEST_BASE/lib/python2.7/site-packages/:$PYTHONPATH"
fi

yum_install_if_not_exist yum-utils git

#install epel & rdo
install_epel
install_rdo

if [[ "`pip -V |awk '{print $2}'`" < "10.0" ]]; then
    pip install --upgrade pip
fi

yum_install_if_not_exist gcc gcc-c++ kernel-devel python-devel openssl-devel python-pip dnsmasq bridge-utils ebtables

if is_service_enabled mariadb; then
    yum_install_if_not_exist mariadb mariadb-server python2-PyMySQL
    configure_mariadb
    systemctl enable mariadb.service
    systemctl start mariadb.service
    do_secure_installation
fi

if is_service_enabled rabbitmq-server; then
    yum_install_if_not_exist rabbitmq-server
    systemctl enable rabbitmq-server.service
    systemctl start rabbitmq-server.service
    tmp_user=$(rabbitmqctl list_users |grep openstack | awk '{print $1}')
    if [[ $tmp_user != "openstack" ]] ; then
        rabbitmqctl add_user openstack $RABBIT_PASSWORD
        rabbitmqctl set_permissions openstack ".*" ".*" ".*"
    fi
fi

if is_service_enabled memcached; then
    yum_install_if_not_exist memcached python-memcached
    sed -i 's/127.0.0.1,::1/127.0.0.1,::1,controller/' /etc/sysconfig/memcached
    systemctl enable memcached.service
    systemctl start memcached.service
fi

if is_service_enabled etcd; then
    yum_install_if_not_exist etcd
    cat <<EOF | sudo tee /etc/etcd/etcd.conf
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://$CONTROLLER_IP:2380"
ETCD_LISTEN_CLIENT_URLS="http://$CONTROLLER_IP:2379"
ETCD_NAME="controller"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://$CONTROLLER_IP:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://$CONTROLLER_IP:2379"
ETCD_INITIAL_CLUSTER="controller=http://$CONTROLLER_IP:2380"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-01"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF

    systemctl enable etcd
    systemctl start etcd
fi

if is_service_enabled httpd; then
    yum_install_if_not_exist httpd mod_wsgi
    systemctl enable httpd
    systemctl start httpd
fi

if is_service_enabled python-openstackclient; then
    pip install python-openstackclient==3.14.1
fi

cat > $TOP_DIR/userrc_early <<EOF
# Use this for debugging issues before files in accrc are created

# Set up password auth credentials now that Keystone is bootstrapped
export OS_IDENTITY_API_VERSION=3
export OS_AUTH_URL=$KEYSTONE_AUTH_URI
export OS_USERNAME=admin
export OS_USER_DOMAIN_ID=default
export OS_PASSWORD=$ADMIN_PASSWORD
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_ID=default
export OS_REGION_NAME=$KEYSTONE_REGION_NAME

EOF

source $TOP_DIR/userrc_early

if is_service_enabled tls-proxy; then
    echo "export OS_CACERT=$INT_CA_DIR/ca-chain.pem" >> $TOP_DIR/userrc_early
    start_tls_proxy http-services '*' 443 $SERVICE_HOST 80
fi

source $TOP_DIR/userrc_early

if is_service_enabled keystone; then
    add_nologin_user keystone
    install_keystone
    configure_keystone
    start_keystone
    bootstrap_keystone
    create_keystone_accounts
fi

if is_service_enabled glance; then
    add_nologin_user glance
    install_glance
    configure_glance
    init_glance
    create_glance_accounts
    add_glance_systemctl
    enable_glance_systemctl
    start_glance
fi

if is_service_enabled nova-compute; then
    yum_install_if_not_exist qemu-kvm qemu-img virt-manager libvirt libvirt-python libvirt-client virt-install virt-viewer bridge-utils
    systemctl enable libvirtd.servic
    systemctl restart libvirtd.service
    
    gpasswd --add nova libvirt
fi

if is_service_enabled nova; then
    add_nologin_user nova
    install_nova
    configure_nova
    init_nova
    create_nova_accounts
    start_nova
fi 

if is_service_enabled nova-compute; then
    su -s /bin/sh -c "$BIN_DIR/nova-manage --config-dir $NOVA_CONF_DIR cell_v2 discover_hosts --verbose" nova
fi

if is_service_enabled neutron; then
    add_nologin_user neutron
    install_neutron
    configure_neutron_new
    configure_neutron_nova_new
    create_neutron_accounts_new
    init_neutron_new
    start_neutron_new
fi

if is_service_enabled horizon; then
    install_horizon
    configure_horizon
    init_horizon
    start_horizon
fi

