#!/bin/bash

# ==============================================================================
# SCRIPT PARA CONTINUAR A INSTALAÇÃO DO AGHU APÓS O PG_RESTORE
# ==============================================================================
set -e

# --- CONFIGURAÇÕES (devem ser as mesmas) ---
DOMAIN="sghmi.itupiranga.pa.gov.br"
ADMIN_EMAIL="dti@itupiranga.pa.gov.br"
INSTALL_DIR="/opt/aghu"
SOURCES_DIR="${INSTALL_DIR}/sources"
DB_NAME="dbaghu"
POSTGRES_USER="postgres"

log() {
    echo "======================================================================"
    echo "-> $(date +'%Y-%m-%d %H:%M:%S') - $1"
    echo "======================================================================"
}

collect_postgres_password() {
    log "Senha do Postgres necessária para continuar"
    read -s -p "Digite a senha para o usuário 'postgres' do sistema: " POSTGRES_OS_PASS; echo
}

# --- FLUXO DE CONTINUAÇÃO ---
main_continuation() {
    collect_postgres_password

    log "Executando migrações do Flyway"
    cd "${SOURCES_DIR}/drop/aghu-db-migration"
    chmod +x flyway
    export PGPASSWORD=$POSTGRES_OS_PASS
    ./flyway -user=${POSTGRES_USER} -url=jdbc:postgresql://127.0.0.1:5432/${DB_NAME} -outOfOrder=true migrate
    unset PGPASSWORD
    
    log "Importando menus e perfis de segurança"
    cd "${SOURCES_DIR}/ArquivosComplementares/aghu-seguranca"
    chmod +x seguranca.sh
    ./seguranca.sh importar-menu jdbc:postgresql://127.0.0.1:5432/${DB_NAME} ${POSTGRES_USER} "'${POSTGRES_OS_PASS}'"
    ./seguranca.sh importar-seguranca jdbc:postgresql://127.0.0.1:5432/${DB_NAME} ${POSTGRES_USER} "'${POSTGRES_OS_PASS}'"

    log "Fazendo deploy da aplicação AGHU (o Wildfly já deve estar rodando)"
    cp "${SOURCES_DIR}/drop/aghu-ear/target/aghu.ear" "${INSTALL_DIR}/wildfly/standalone/deployments/"

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

main_continuation
