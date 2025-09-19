#!/bin/bash

# ==============================================================================
#
# Guia de Instalação Unificada do AGHU - Itupiranga (VERSÃO DEFINITIVA v2)
# CORREÇÃO: Usuário de serviço criado com um shell válido (/bin/bash)
#
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
    read -s -p "Digite a senha para o usuário 'postgres' do sistema: " POSTGRES_OS_PASS; echo
    read -s -p "Digite a senha para o administrador do OpenLDAP: " LDAP_ADMIN_PASS; echo
    read -s -p "Digite a senha para 'ugen_aghu' do DB: " UGHU_DB_PASS; echo
    read -s -p "Digite a senha para 'ugen_quartz' do DB: " QUARTZ_DB_PASS; echo
    read -s -p "Digite a senha para 'ugen_seguranca' do DB: " SEGURANCA_DB_PASS; echo
    read -s -p "Digite a senha para o admin do Wildfly: " WILDFLY_ADMIN_PASS; echo
}

prepare_system() {
    log "Limpando instalações antigas para um começo limpo"
    systemctl stop wildfly.service || true
    rm -rf /etc/systemd/system/wildfly.service /etc/default/wildfly
    rm -rf ${INSTALL_DIR}

    log "Atualizando sistema e instalando dependências essenciais"
    apt-get update && apt-get upgrade -y
    apt-get install -y wget curl vim unzip htop git gnupg lsb-release ca-certificates apt-transport-https python3-pip debconf-utils apache2 certbot python3-certbot-apache cups
    
    log "Instalando OpenJDK 11 (padrão do sistema)"
    apt-get install -y openjdk-11-jdk
    
    log "Instalando 'gdown' para downloads do Google Drive"
    pip3 install gdown
    
    log "Criando diretórios de base"
    mkdir -p "${SOURCES_DIR}"
}

setup_database() {
    log "Instalando e configurando PostgreSQL 15 via repositório oficial"
    apt-get install -y postgresql-common
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    apt-get update
    apt-get install -y postgresql-15

    echo "${POSTGRES_USER}:${POSTGRES_OS_PASS}" | chpasswd
    
    log "Ajustando configurações do PostgreSQL"
    PG_CONF="/etc/postgresql/15/main/postgresql.conf"
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
    echo "log_timezone = 'America/Sao_Paulo'" >> "$PG_CONF"
    echo "timezone = 'America/Sao_Paulo'" >> "$PG_CONF"
    PG_HBA="/etc/postgresql/15/main/pg_hba.conf"
    echo "host    all             all             127.0.0.1/32            md5" >> "$PG_HBA"
    systemctl restart postgresql

    log "Recriando banco de dados e roles para garantir um ambiente limpo"
    sudo -u ${POSTGRES_USER} psql -d postgres <<EOF
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}';
DROP DATABASE IF EXISTS ${DB_NAME};
DROP ROLE IF EXISTS ugen_aghu; DROP ROLE IF EXISTS ugen_quartz; DROP ROLE IF EXISTS ugen_seguranca; DROP ROLE IF EXISTS acesso_completo; DROP ROLE IF EXISTS acesso_leitura;
CREATE ROLE acesso_leitura;
CREATE ROLE acesso_completo NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE ROLE ugen_aghu LOGIN PASSWORD '${UGHU_DB_PASS}'; GRANT acesso_completo TO ugen_aghu;
CREATE ROLE ugen_quartz LOGIN PASSWORD '${QUARTZ_DB_PASS}';
CREATE ROLE ugen_seguranca LOGIN PASSWORD '${SEGURANCA_DB_PASS}'; GRANT acesso_completo TO ugen_seguranca;
CREATE DATABASE ${DB_NAME};
EOF
}

setup_ldap() {
    log "Instalando e configurando o OpenLDAP de forma automatizada"
    echo "slapd slapd/root_password password ${LDAP_ADMIN_PASS}" | debconf-set-selections
    echo "slapd slapd/root_password_again password ${LDAP_ADMIN_PASS}" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y slapd ldap-utils
}

setup_application() {
    log "Instalando Wildfly 26"
    cd "${SOURCES_DIR}"
    wget https://github.com/wildfly/wildfly/releases/download/26.1.3.Final/wildfly-26.1.3.Final.tar.gz
    mkdir -p "${INSTALL_DIR}/wildfly"
    tar -xvzf wildfly-26.1.3.Final.tar.gz -C "${INSTALL_DIR}/wildfly" --strip-components=1

    # ROBUSTEZ: Cria e verifica o usuário 'aghu' com um shell válido
    log "Criando usuário de serviço 'aghu' com shell /bin/bash"
    if id "${APP_USER}" &>/dev/null; then
        log "Usuário '${APP_USER}' já existe. Removendo e recriando para garantir o shell correto."
        userdel ${APP_USER}
    fi
    # A ALTERAÇÃO CRÍTICA ESTÁ AQUI
    useradd -r -m -s /bin/bash -d "${INSTALL_DIR}/wildfly" ${APP_USER}
    log "Usuário '${APP_USER}' criado com shell /bin/bash."
    id -u ${APP_USER} >/dev/null

    log "Configurando serviço do Wildfly (versão simplificada)"
    cat <<EOF > /etc/systemd/system/wildfly.service
[Unit]
Description=The WildFly Application Server AGHU
After=syslog.target network.target

[Service]
User=aghu
Group=aghu
ExecStart=/opt/aghu/wildfly/bin/standalone.sh -b=0.0.0.0 -bmanagement=0.0.0.0

[Install]
WantedBy=multi-user.target
EOF
    
    sed -i 's/-Xms64m/-Xms2g/' ${INSTALL_DIR}/wildfly/bin/standalone.conf
    sed -i 's/-Xmx512m/-Xmx4g/' ${INSTALL_DIR}/wildfly/bin/standalone.conf
    
    chown -R ${APP_USER}:${APP_USER} "${INSTALL_DIR}"
    
    log "Adicionando usuário de gerenciamento 'admin'"
    ${INSTALL_DIR}/wildfly/bin/add-user.sh admin ${WILDFLY_ADMIN_PASS} --silent
    
    log "Baixando e preparando arquivos da aplicação"
    gdown --id "${SYSTEM_FILE_ID}" -O "${SOURCES_DIR}/sistema.zip"
    gdown --id "${COMPLEMENTARES_FILE_ID}" -O "${SOURCES_DIR}/complementares.zip"
    unzip -o "${SOURCES_DIR}/sistema.zip" -d "${SOURCES_DIR}"
    unzip -o "${SOURCES_DIR}/complementares.zip" -d "${SOURCES_DIR}"

    log "Extraindo módulos aninhados"
    INNER_MODULES_ZIP="${SOURCES_DIR}/ArquivosComplementares/Modules/aghu-wildfly-modules.zip"
    unzip -o "${INNER_MODULES_ZIP}" -d "${INSTALL_DIR}/wildfly/"

    chown -R ${APP_USER}:${APP_USER} "${INSTALL_DIR}"

    log "Iniciando Wildfly..."
    systemctl daemon-reload
    systemctl start wildfly

    log "Aguardando Wildfly iniciar completamente (pode levar alguns minutos)..."
    TIMEOUT=300; START_TIME=$SECONDS
    while ! grep -q "WFLYSRV0025" "${INSTALL_DIR}/wildfly/standalone/log/server.log" 2>/dev/null; do
        if (( SECONDS - START_TIME > TIMEOUT )); then
            echo "ERRO: Tempo limite de ${TIMEOUT}s excedido esperando pelo Wildfly."
            journalctl -xeu wildfly.service --no-pager
            exit 1
        fi
        printf "."
        sleep 5
    done
    echo -e "\nWildfly iniciado com sucesso!"

    JBOSS_CLI="${INSTALL_DIR}/wildfly/bin/jboss-cli.sh --connect --user=admin --password=${WILDFLY_ADMIN_PASS}"
    
    log "Configurando DataSource no Wildfly"
    $JBOSS_CLI "/subsystem=datasources/jdbc-driver=postgresql:add(driver-name=postgresql,driver-module-name=org.postgresql.jdbc,driver-class-name=org.postgresql.Driver)"
    $JBOSS_CLI "data-source add --name=aghuDatasource --jndi-name=java:/aghuDatasource --driver-name=postgresql --connection-url=jdbc:postgresql://127.0.0.1:5432/${DB_NAME} --user-name=ugen_aghu --password=${UGHU_DB_PASS} --validate-on-match=true --min-pool-size=5 --max-pool-size=50"

    log "Restaurando banco de dados"
    BACKUP_FILE_SOURCE="${SOURCES_DIR}/ArquivosComplementares/Base Zero/dbaghu_aghu1_0.backup"
    BACKUP_FILE_TMP="/tmp/dbaghu_aghu1_0.backup"
    gunzip -f "${BACKUP_FILE_SOURCE}.gz"
    cp "${BACKUP_FILE_SOURCE}" "${BACKUP_FILE_TMP}"
    chown ${POSTGRES_USER}:${POSTGRES_USER} "${BACKUP_FILE_TMP}"
    sudo -u ${POSTGRES_USER} pg_restore -d ${DB_NAME} --clean --if-exists "${BACKUP_FILE_TMP}" -v
    rm -f "${BACKUP_FILE_TMP}"

    log "Executando migrações do Flyway"
    cd "${SOURCES_DIR}/drop/aghu-db-migration"; chmod +x flyway
    export PGPASSWORD=$POSTGRES_OS_PASS
    ./flyway -user=${POSTGRES_USER} -url=jdbc:postgresql://127.0.0.1:5432/${DB_NAME} -outOfOrder=true migrate
    unset PGPASSWORD
    
    log "Importando menus e perfis de segurança"
    cd "${SOURCES_DIR}/ArquivosComplementares/aghu-seguranca"
    chmod +x seguranca.sh
    ./seguranca.sh importar-menu jdbc:postgresql://127.0.0.1:5432/${DB_NAME} ${POSTGRES_USER} "${POSTGRES_OS_PASS}"
    ./seguranca.sh importar-seguranca jdbc:postgresql://127.0.0.1:5432/${DB_NAME} ${POSTGRES_USER} "${POSTGRES_OS_PASS}"

    log "Fazendo deploy da aplicação AGHU"
    cp "${SOURCES_DIR}/drop/aghu-ear/target/aghu.ear" "${INSTALL_DIR}/wildfly/standalone/deployments/"

    log "Configuração da aplicação finalizada."
}

setup_apache_and_finalize() {
    log "Configurando Apache como Proxy Reverso e gerando SSL"
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
    systemctl restart apache2
    certbot --apache -d "${DOMAIN}" --non-interactive --agree-tos -m "${ADMIN_EMAIL}" --redirect
    systemctl restart apache2
    
    log "Habilitando Wildfly para iniciar com o sistema"
    systemctl enable wildfly
    
    clear
    log "INSTALAÇÃO DEFINITIVA FINALIZADA COM SUCESSO!"
    echo "======================================================================"
    echo ""
    echo "Aguarde de 2 a 5 minutos para o deploy completo da aplicação."
    echo "Monitore o progresso com: tail -f /opt/aghu/wildfly/standalone/log/server.log"
    echo ""
    echo "Acesse o sistema em: https://${DOMAIN}"
    echo ""
    echo "Lembre-se dos próximos passos: criar usuários no OpenLDAP e configurar"
    echo "o arquivo app-parameters.properties."
    echo ""
    echo "======================================================================"
}

# --- FLUXO DE EXECUÇÃO ---
main() {
    collect_passwords
    prepare_system
    setup_database
    setup_ldap
    setup_application
    setup_apache_and_finalize
}

main
