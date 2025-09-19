#!/bin/bash
set -e
# ==============================================================================
# AGHU Unificado - Script ajustado (inclui downloads via Google Drive IDs)
# Execute como root em Debian 11
# ==============================================================================

# -----------------------
# Variáveis (edite se necessário)
# -----------------------
DOMAIN="sghmi.itupiranga.pa.gov.br"
ADMIN_EMAIL="dti@itupiranga.pa.gov.br"

# IDs dos arquivos no Google Drive (fornecidos por você)
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
  log "Informe as senhas (não serão exibidas)"
  read -s -p "Senha do superusuário PostgreSQL (postgres): " POSTGRES_DB_PASS; echo
  read -s -p "Senha para ugen_aghu (DB): " UGEN_AGHU_PASS; echo
  read -s -p "Senha para ugen_quartz (DB): " UGEN_QUARTZ_PASS; echo
  read -s -p "Senha para ugen_seguranca (DB): " UGEN_SEGURANCA_PASS; echo
  read -s -p "Senha admin do Wildfly: " WILDFLY_ADMIN_PASS; echo
  read -s -p "Senha admin OpenLDAP (slapd): " LDAP_ADMIN_PASS; echo
}

prepare_system() {
  log "Atualizando e instalando pacotes base"
  apt-get update && apt-get upgrade -y
  apt-get install -y wget curl vim unzip htop git gnupg lsb-release ca-certificates \
    apt-transport-https python3-pip debconf-utils apache2 certbot python3-certbot-apache \
    cups slapd ldap-utils unzip sudo

  # Java 8 preferencial (se não disponível, instala Java 11)
  if apt-get install -y openjdk-8-jdk; then
    log "OpenJDK 8 instalado"
  else
    log "OpenJDK 8 não disponível — instalando OpenJDK 11"
    apt-get install -y openjdk-11-jdk
  fi

  log "Instalando gdown (download Google Drive)"
  pip3 install --upgrade pip
  pip3 install gdown

  log "Criando diretórios"
  mkdir -p "${SOURCES_DIR}"
  chown -R root:root "${INSTALL_DIR}" || true
}

setup_postgresql() {
  log "Instalando PostgreSQL 15 via repositório oficial"
  apt-get install -y postgresql-common
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
  apt-get update
  apt-get install -y postgresql-15

  log "Ajustando postgresql.conf e pg_hba.conf"
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

  cat > "$PG_HBA" <<EOF
local   all             all                                     peer
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
EOF

  systemctl restart postgresql
  sleep 3

  log "Configurar senha do usuário postgres (DB)"
  sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_DB_PASS}';"

  log "Criando banco ${DB_NAME} e roles de aplicação"
  sudo -u postgres psql <<SQL
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME};
DROP ROLE IF EXISTS ugen_aghu;
DROP ROLE IF EXISTS ugen_quartz;
DROP ROLE IF EXISTS ugen_seguranca;
DROP ROLE IF EXISTS acesso_completo;
DROP ROLE IF EXISTS acesso_leitura;

CREATE ROLE acesso_leitura;
CREATE ROLE acesso_completo NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE ROLE ugen_aghu LOGIN PASSWORD '${UGEN_AGHU_PASS}'; GRANT acesso_completo TO ugen_aghu;
CREATE ROLE ugen_quartz LOGIN PASSWORD '${UGEN_QUARTZ_PASS}';
CREATE ROLE ugen_seguranca LOGIN PASSWORD '${UGEN_SEGURANCA_PASS}'; GRANT acesso_completo TO ugen_seguranca;
SQL

}

setup_wildfly_and_app() {
  log "Instalando WildFly 9.0.2 (homologado pelo manual)"
  cd "${SOURCES_DIR}"
  wget -q https://download.jboss.org/wildfly/9.0.2.Final/wildfly-9.0.2.Final.tar.gz
  mkdir -p "${INSTALL_DIR}/wildfly"
  tar -xzf wildfly-9.0.2.Final.tar.gz -C "${INSTALL_DIR}/wildfly" --strip-components=1

  log "Criando usuário de serviço ${APP_USER}"
  if id "${APP_USER}" &>/dev/null; then
    log "Usuário ${APP_USER} já existe"
  else
    useradd -r -m -s /bin/bash -d "${INSTALL_DIR}/wildfly" "${APP_USER}"
  fi
  chown -R ${APP_USER}:${APP_USER} "${INSTALL_DIR}"

  log "Ajustando heap do WildFly para ambiente pequeno"
  sed -i 's/-Xms64m/-Xms2g/' ${INSTALL_DIR}/wildfly/bin/standalone.conf
  sed -i 's/-Xmx512m/-Xmx4g/' ${INSTALL_DIR}/wildfly/bin/standalone.conf

  cat > /etc/systemd/system/wildfly.service <<EOF
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

  systemctl daemon-reload
  systemctl enable wildfly
  systemctl start wildfly

  # aguardar startup do Wildfly (WFLYSRV0025 aparece no log quando pronto)
  log "Aguardando Wildfly iniciar..."
  TIMEOUT=300; START=$SECONDS
  while ! grep -q "WFLYSRV0025" "${INSTALL_DIR}/wildfly/standalone/log/server.log" 2>/dev/null; do
    if (( SECONDS - START > TIMEOUT )); then
      log "Timeout aguardando Wildfly. Verifique logs: journalctl -u wildfly -n 200"
      break
    fi
    printf "."; sleep 3
  done
  echo

  log "Adicionando usuário de administração ao Wildfly (management user)"
  # add-user.sh pode ser interativo; --silent é suportado em algumas versões. Se falhar, rodar manualmente.
  ${INSTALL_DIR}/wildfly/bin/add-user.sh admin ${WILDFLY_ADMIN_PASS} --silent || true

  # instalar driver JDBC no Wildfly
  log "Instalando driver JDBC PostgreSQL"
  JDBC_VERSION="postgresql-42.7.3.jar"
  wget -q https://jdbc.postgresql.org/download/${JDBC_VERSION} -P "${SOURCES_DIR}"
  MODULE_PATH="${INSTALL_DIR}/wildfly/modules/org/postgresql/jdbc/main"
  mkdir -p "${MODULE_PATH}"
  mv "${SOURCES_DIR}/${JDBC_VERSION}" "${MODULE_PATH}/"
  cat > "${MODULE_PATH}/module.xml" <<XML
<?xml version="1.0" ?>
<module xmlns="urn:jboss:module:1.3" name="org.postgresql.jdbc">
  <resources>
    <resource-root path="${JDBC_VERSION}"/>
  </resources>
  <dependencies>
    <module name="javax.api"/>
    <module name="javax.transaction.api"/>
  </dependencies>
</module>
XML
  chown -R ${APP_USER}:${APP_USER} "${INSTALL_DIR}"
}

download_and_deploy_app() {
  log "Baixando pacotes do Google Drive (sistema + complementares)"
  mkdir -p "${SOURCES_DIR}"
  cd "${SOURCES_DIR}"

  # gdown baixa pelo ID
  gdown --id "${SYSTEM_FILE_ID}" -O sistema.zip
  gdown --id "${COMPLEMENTARES_FILE_ID}" -O complementares.zip

  log "Descompactando pacotes"
  unzip -o sistema.zip -d "${SOURCES_DIR}/sistema"
  unzip -o complementares.zip -d "${SOURCES_DIR}/complementares"

  # Procurar backup do BD dentro das pastas extraídas
  BACKUP_FILE=$(find "${SOURCES_DIR}" -type f -iname "dbaghu*.backup*" -print -quit)
  if [ -z "${BACKUP_FILE}" ]; then
    log "Aviso: não encontrei arquivo de backup (dbaghu_*.backup). Pule essa etapa manualmente."
  else
    log "Backup encontrado: ${BACKUP_FILE}"
    # se comprimido em .gz
    if [[ "${BACKUP_FILE}" == *.gz ]]; then
      gunzip -f "${BACKUP_FILE}"
      BACKUP_FILE="${BACKUP_FILE%.gz}"
    fi

    # restaurar usando usuário postgres (conexão via socket local)
    log "Restaurando backup para ${DB_NAME} (isso pode levar alguns minutos)..."
    sudo -u postgres pg_restore --clean --if-exists -d "${DB_NAME}" "${BACKUP_FILE}" -v || {
      log "pg_restore retornou erro. Verifique /var/log/postgresql/* e aguarde para reexecutar manualmente."
    }
  fi

  # Flyway (se presente)
  FLYWAY_DIR=$(find "${SOURCES_DIR}" -type d -iname "aghu-db-migration*" -print -quit)
  if [ -n "${FLYWAY_DIR}" ]; then
    log "Executando Flyway (migrations)"
    cd "${FLYWAY_DIR}"
    chmod +x ./flyway || true
    # usa usuário de conexão do DB (ugen_aghu)
    ./flyway -user=ugen_aghu -password=${UGEN_AGHU_PASS} -url=jdbc:postgresql://127.0.0.1:5432/${DB_NAME} -outOfOrder=true migrate || log "Flyway retornou aviso/erro — verifique logs."
  else
    log "Flyway não encontrado em ${SOURCES_DIR}; pulando migrations automáticas."
  fi

  # importar seguranca (menus/perfis) se existir script
  SEGURANCA_SH=$(find "${SOURCES_DIR}" -type f -iname "seguranca.sh" -print -quit)
  if [ -n "${SEGURANCA_SH}" ]; then
    log "Importando menus/perfis de segurança via seguranca.sh"
    chmod +x "${SEGURANCA_SH}"
    # script espera: importar-menu jdbc:... user 'password'
    ${SEGURANCA_SH} importar-menu "jdbc:postgresql://127.0.0.1:5432/${DB_NAME}" "${POSTGRES_USER}" "'${POSTGRES_DB_PASS}'" || log "Aviso: importar-menu retornou não-zero"
    ${SEGURANCA_SH} importar-seguranca "jdbc:postgresql://127.0.0.1:5432/${DB_NAME}" "${POSTGRES_USER}" "'${POSTGRES_DB_PASS}'" || log "Aviso: importar-seguranca retornou não-zero"
  else
    log "seguranca.sh não encontrado; pule importações de segurança manualmente."
  fi

  # localizar EAR e copiar para deployments
  AGHU_EAR=$(find "${SOURCES_DIR}" -type f -iname "aghu*.ear" -print -quit)
  if [ -n "${AGHU_EAR}" ]; then
    log "Deploy do aghu.ear encontrado em ${AGHU_EAR}"
    cp -p "${AGHU_EAR}" "${INSTALL_DIR}/wildfly/standalone/deployments/"
    chown ${APP_USER}:${APP_USER} "${INSTALL_DIR}/wildfly/standalone/deployments/$(basename ${AGHU_EAR})"
    log "Deploy realizado (Wildfly fará o hot-deploy)."
  else
    log "ERRO: aghu.ear não encontrado nas pastas baixadas. Coloque manualmente em ${INSTALL_DIR}/wildfly/standalone/deployments/"
  fi

  # reiniciar Wildfly para garantir
  systemctl restart wildfly
}

setup_apache_and_ssl() {
  log "Configurando Apache (proxy reverso) e gerando certificado Let's Encrypt"
  cat > /etc/apache2/sites-available/aghu.conf <<EOF
<VirtualHost *:80>
  ServerName ${DOMAIN}
  ProxyPreserveHost On
  ProxyPass / http://127.0.0.1:8080/aghu/
  ProxyPassReverse / http://127.0.0.1:8080/aghu/
  ErrorLog \${APACHE_LOG_DIR}/aghu_error.log
  CustomLog \${APACHE_LOG_DIR}/aghu_access.log combined
</VirtualHost>
EOF

  a2enmod proxy proxy_http rewrite headers ssl
  a2ensite aghu.conf
  a2dissite 000-default.conf || true
  systemctl reload apache2

  # Certbot (domínio já propagado conforme informado)
  certbot --apache -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --non-interactive --redirect || {
    log "Certbot retornou erro — verifique se a porta 80 está acessível e o domínio aponta para este servidor."
  }
  systemctl restart apache2
}

setup_ldap_base() {
  log "Criando base LDIF padrão para OpenLDAP (dc=itupiranga,dc=pa,dc=gov,dc=br)"
  BASE_LDIF="/tmp/base_itupiranga.ldif"
  cat > "${BASE_LDIF}" <<LDIF
dn: dc=itupiranga,dc=pa,dc=gov,dc=br
objectClass: top
objectClass: dcObject
objectClass: organization
o: Prefeitura de Itupiranga
dc: itupiranga

dn: ou=usuarios,dc=itupiranga,dc=pa,dc=gov,dc=br
objectClass: organizationalUnit
ou: usuarios

dn: uid=admin,ou=usuarios,dc=itupiranga,dc=pa,dc=gov,dc=br
objectClass: inetOrgPerson
cn: admin
sn: admin
uid: admin
userPassword: ${LDAP_ADMIN_PASS}
LDIF

  # Importa (assume slapd em execução)
  ldapadd -x -D "cn=admin,dc=itupiranga,dc=pa,dc=gov,dc=br" -w "${LDAP_ADMIN_PASS}" -f "${BASE_LDIF}" || log "Aviso: ldapadd falhou - verifique configuração do slapd e credenciais."
}

main() {
  collect_passwords
  prepare_system
  setup_postgresql
  setup_wildfly_and_app
  download_and_deploy_app
  setup_apache_and_ssl
  setup_ldap_base

  log "Instalação concluída. Acesse: https://${DOMAIN}"
  echo "Verifique logs: tail -f ${INSTALL_DIR}/wildfly/standalone/log/server.log"
}

main
