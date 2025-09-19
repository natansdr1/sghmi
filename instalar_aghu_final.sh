#!/bin/bash

# ==============================================================================
# Guia de Instalação Unificada do AGHU - Itupiranga (Versão Final v3)
# Baseado no manual da EBSERH + ajustes para hospital pequeno (2 vCPU / 8 GB RAM)
# ==============================================================================

set -e

# --- CONFIGURAÇÕES PRINCIPAIS ---
DOMAIN="sghmi.itupiranga.pa.gov.br"
ADMIN_EMAIL="dti@itupiranga.pa.gov.br"
SYSTEM_FILE_ID="1Oo7yDW2ChA_w3qcp275YdQJnbjb6nIHS"
COMPLEMENTARES_FILE_ID="1y7tm9uhL2Pe4c-O88qOBhPFFWBtgoZot"
INSTALL_DIR="/opt/aghu"
SOURCES_DIR="${INSTALL_DIR}/sources"
DB_NAME="dbaghu"
POSTGRES_USER="postgres"
APP_USER="aghu"

log() {
    echo "======================================================================"
    echo "-> $(date +'%Y-%m-%d %H:%M:%S') - $1"
    echo "======================================================================"
}

collect_passwords() {
    log "Configuração de Senhas (não serão exibidas)"
    read -s -p "Senha para o usuário 'postgres' do banco: " POSTGRES_DB_PASS; echo
    read -s -p "Senha para 'ugen_aghu' do DB: " UGHU_DB_PASS; echo
    read -s -p "Senha para 'ugen_quartz' do DB: " QUARTZ_DB_PASS; echo
    read -s -p "Senha para 'ugen_seguranca' do DB: " SEGURANCA_DB_PASS; echo
    read -s -p "Senha para o admin do Wildfly: " WILDFLY_ADMIN_PASS; echo
    read -s -p "Senha para o admin do OpenLDAP: " LDAP_ADMIN_PASS; echo
}

prepare_system() {
    log "Atualizando sistema e instalando dependências essenciais"
    apt-get update && apt-get upgrade -y
    apt-get install -y wget curl vim unzip htop git gnupg lsb-release ca-certificates apt-transport-https \
        python3-pip debconf-utils apache2 certbot python3-certbot-apache cups openjdk-8-jdk slapd ldap-utils
    
    log "Criando diretórios de base"
    mkdir -p "${SOURCES_DIR}"

    log "Instalando gdown (Google Drive) com --break-system-packages"
    pip3 install gdown --break-system-packages
}

setup_database() {
    log "Instalando PostgreSQL 15 via repositório oficial"
    apt-get install -y postgresql-common
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    apt-get update
    apt-get install -y postgresql-15

    log "Configurando PostgreSQL para uso no AGHU"
    PG_CONF="/etc/postgresql/15/main/postgresql.conf"
    PG_HBA="/etc/postgresql/15/main/pg_hba.conf"
    
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
    cat <<EOF >> "$PG_CONF"
log_timezone = 'America/Sao_Paulo'
timezone = 'America/Sao_Paulo'
password_encryption = md5
max_connections = 50
shared_buffers = 512MB
work_mem = 8MB
maintenance_work_mem = 128MB
effective_cache_size = 2GB
EOF

    echo "local   all             all                                     peer" > "$PG_HBA"
    echo "host    all             all             127.0.0.1/32            md5" >> "$PG_HBA"
    echo "host    all             all             ::1/128                 md5" >> "$PG_HBA"

    systemctl restart postgresql
    sleep 5

    log "Configurando senha do superusuário 'postgres'"
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_DB_PASS}';"

    log "Criando banco de dados e roles iniciais"
    sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME};
DROP ROLE IF EXISTS ugen_aghu; DROP ROLE IF EXISTS ugen_quartz; DROP ROLE IF EXISTS ugen_seguranca;
DROP ROLE IF EXISTS acesso_completo; DROP ROLE IF EXISTS acesso_leitura;

CREATE ROLE acesso_leitura;
CREATE ROLE acesso_completo NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;

CREATE ROLE ugen_aghu LOGIN PASSWORD '${UGHU_DB_PASS}'; GRANT acesso_completo TO ugen_aghu;
CREATE ROLE ugen_quartz LOGIN PASSWORD '${QUARTZ_DB_PASS}';
CREATE ROLE ugen_seguranca LOGIN PASSWORD '${SEGURANCA_DB_PASS}'; GRANT acesso_completo TO ugen_seguranca;
EOF
}

setup_wildfly() {
    log "Instalando Wildfly 9.0.2 (homologado pela EBSERH)"
    cd "${SOURCES_DIR}"
    wget https://download.jboss.org/wildfly/9.0.2.Final/wildfly-9.0.2.Final.tar.gz
    mkdir -p "${INSTALL_DIR}/wildfly"
    tar -xvzf wildfly-9.0.2.Final.tar.gz -C "${INSTALL_DIR}/wildfly" --strip-components=1

    log "Criando usuário de serviço '${APP_USER}'"
    useradd -r -m -s /bin/bash -d "${INSTALL_DIR}/wildfly" ${APP_USER} || true
    chown -R ${APP_USER}:${APP_USER} "${INSTALL_DIR}"

    log "Ajustando memória do Wildfly para ambiente pequeno (4 GB máx)"
    sed -i 's/-Xms64m/-Xms2g/' ${INSTALL_DIR}/wildfly/bin/standalone.conf
    sed -i 's/-Xmx512m/-Xmx4g/' ${INSTALL_DIR}/wildfly/bin/standalone.conf

    log "Criando serviço systemd do Wildfly"
    cat <<EOF > /etc/systemd/system/wildfly.service
[Unit]
Description=WildFly Application Server AGHU
After=network.target

[Service]
User=${APP_USER}
Group=${APP_USER}
ExecStart=${INSTALL_DIR}/wildfly/bin/standalone.sh -b 0.0.0.0
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    log "Adicionando usuário admin ao Wildfly"
    ${INSTALL_DIR}/wildfly/bin/add-user.sh admin ${WILDFLY_ADMIN_PASS} --silent

    systemctl daemon-reload
    systemctl enable wildfly
    systemctl start wildfly
}

setup_apache() {
    log "Configurando Apache como proxy reverso com SSL"
    cat <<EOF > /etc/apache2/sites-available/aghu.conf
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:8080/aghu/
    ProxyPassReverse / http://127.0.0.1:8080/aghu/
</VirtualHost>
EOF
    a2enmod proxy proxy_http rewrite headers ssl
    a2ensite aghu.conf; a2dissite 000-default.conf
    systemctl reload apache2

    log "Gerando certificado SSL com Let's Encrypt"
    certbot --apache -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --non-interactive --redirect
    systemctl restart apache2
}

setup_cups() {
    log "Instalando e ativando CUPS (impressão)"
    apt-get install -y cups
    systemctl enable cups
    systemctl start cups
}

setup_ldap() {
    log "Configurando senha do admin do OpenLDAP"
    echo "slapd slapd/root_password password ${LDAP_ADMIN_PASS}" | debconf-set-selections
    echo "slapd slapd/root_password_again password ${LDAP_ADMIN_PASS}" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y slapd ldap-utils
}

download_files() {
    log "Baixando arquivos do AGHU do Google Drive"
    cd "${SOURCES_DIR}"
    gdown --id "${SYSTEM_FILE_ID}" -O sistema.zip
    gdown --id "${COMPLEMENTARES_FILE_ID}" -O complementares.zip
    unzip -o sistema.zip -d "${SOURCES_DIR}"
    unzip -o complementares.zip -d "${SOURCES_DIR}"
}

final_message() {
    clear
    log "INSTALAÇÃO FINALIZADA COM SUCESSO!"
    echo ""
    echo "Acesse o sistema em: https://${DOMAIN}"
    echo "Verifique o log do Wildfly com: tail -f ${INSTALL_DIR}/wildfly/standalone/log/server.log"
    echo ""
    echo "IMPORTANTE:"
    echo " - Copie o arquivo aghu.ear para ${INSTALL_DIR}/wildfly/standalone/deployments/"
    echo " - Configure o OpenLDAP com base (dc=itupiranga,dc=pa,dc=gov,dc=br)"
    echo " - Ajuste o arquivo app-parameters.properties do AGHU"
    echo ""
}

main() {
    collect_passwords
    prepare_system
    setup_database
    setup_wildfly
    setup_apache
    setup_cups
    setup_ldap
    download_files
    final_message
}

main
