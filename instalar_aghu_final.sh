#!/bin/bash

# ==============================================================================
#
# Guia de Instalação Unificada do AGHU - Itupiranga (VERSÃO LEGADO ROBUSTO)
# Instala o ambiente exigido pelo manual (Wildfly 9/Java 8) com todas as 
# correções e melhorias de robustez que descobrimos.
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
    
    log "Instalando 'gdown' para downloads do Google Drive"
    pip3 install gdown
    
    log "Criando diretórios de base"
    mkdir -p "${SOURCES_DIR}"
}

setup_java8() {
    log "Instalando Java 8 (OpenJDK/Temurin) via repositório externo"
    apt-get install -y gpg
    wget -O - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor | tee /usr/share/keyrings/adoptium.gpg > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/adoptium.list
    apt-get update
    apt-get install -y temurin-8-jdk
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
    PG_HBA="/etc/postgresql/15/main/pg_hba.conf"
    
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
    echo "log_timezone = 'America/Sao_Paulo'" >> "$PG_CONF"
    echo "timezone = 'America/Sao_Paulo'" >> "$PG_CONF"
    echo "password_encryption = md5" >> "$PG_CONF"

    log "Configurando autenticação 'trust' temporária para setup inicial"
    sed -i -E "s/^(local\s+all\s+all\s+)peer/\1trust/" "$PG_HBA"
    systemctl restart postgresql
    sleep 5

    log "Definindo senha para o superusuário 'postgres' do banco de dados"
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${POSTGRES_OS_PASS}';"

    log "Criando banco de dados e roles"
    sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME};
EOF
    
    sudo -u postgres psql -d ${DB_NAME} <<EOF
DROP ROLE IF EXISTS ugen_aghu; DROP ROLE IF EXISTS ugen_quartz; DROP ROLE IF EXISTS ugen_seguranca; DROP ROLE IF EXISTS acesso_completo; DROP ROLE IF EXISTS acesso_leitura;
CREATE ROLE acesso_leitura;
CREATE ROLE acesso_completo NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE ROLE ugen_aghu LOGIN PASSWORD '${UGHU_DB_PASS}'; GRANT acesso_completo TO ugen_aghu;
CREATE ROLE ugen_quartz LOGIN PASSWORD '${QUARTZ_DB_PASS}';
CREATE ROLE ugen_seguranca LOGIN PASSWORD '${SEGURANCA_DB_PASS}'; GRANT acesso_completo TO ugen_seguranca;
EOF

    log "Restaurando autenticação segura (md5) para o PostgreSQL"
    sed -i -E "s/^(local\s+all\s+all\s+)trust/\1peer/" "$PG_HBA"
    echo "host    all             all             127.0.0.1/32            md5" >> "$PG_HBA"
    echo "host    all             all             ::1/128                 md5" >> "$PG_HBA"
    systemctl restart postgresql
}

setup_ldap() {
    log "Instalando e configurando o OpenLDAP de forma automatizada"
    echo "slapd slapd/root_password password ${LDAP_ADMIN_PASS}" | debconf-set-selections
    echo "slapd slapd/root_password_again password ${LDAP_ADMIN_PASS}" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt-get install -y slapd ldap-utils
}

setup_application() {
    log "Instalando Wildfly 9.0.2"
    cd "${SOURCES_DIR}"
    wget https://download.jboss.org/wildfly/9.0.2.Final/wildfly-9.0.2.Final.tar.gz
    mkdir -p "${INSTALL_DIR}/wildfly"
    tar -xvzf wildfly-9.0.2.Final.tar.gz -C "${INSTALL_DIR}/wildfly" --strip-components=1

    log "Baixando e instalando o driver JDBC do PostgreSQL"
    wget https://jdbc.postgresql.org/download/postgresql-42.2.27.jar -P "${SOURCES_DIR}" # Versão compatível com Java 8
    MODULE_PATH="${INSTALL_DIR}/wildfly/modules/org/postgresql/main" # Caminho diferente para Wildfly 9
    mkdir -p "${MODULE_PATH}"
    mv "${SOURCES_DIR}/postgresql-42.2.27.jar" "${MODULE_PATH}/"
    cat <<EOF > "${MODULE_PATH}/module.xml"
<?xml version="1.0" ?>
<module xmlns="urn:jboss:module:1.3" name="org.postgresql">
    <resources>
        <resource-root path="postgresql-42.2.27.jar"/>
    </resources>
    <dependencies>
        <module name="javax.api"/>
        <module name="javax.transaction.api"/>
    </dependencies>
</module>
EOF
    
    log "Criando usuário de serviço 'aghu' com shell /bin/bash"
    if id "${APP_USER}" &>/dev/null; then userdel ${APP_USER}; fi
    useradd -r -m -s /bin/bash -d "${INSTALL_DIR}/wildfly" ${APP_USER}
    id -u ${APP_USER} >/dev/null

    log "Configurando Wildfly (standalone.xml) automaticamente"
    # Sobrescreve o standalone.xml com uma versão corrigida para evitar erros de sintaxe
    bash -c 'cat <<\'EOF\' > /opt/aghu/wildfly/standalone/configuration/standalone.xml
<?xml version="1.0" encoding="UTF-8"?>
<server xmlns="urn:jboss:domain:2.2">
    <extensions>
        <extension module="org.jboss.as.clustering.infinispan"/>
        <extension module="org.jboss.as.connector"/>
        <extension module="org.jboss.as.deployment-scanner"/>
        <extension module="org.jboss.as.ee"/>
        <extension module="org.jboss.as.ejb3"/>
        <extension module="org.jboss.as.jacorb"/>
        <extension module="org.jboss.as.jaxrs"/>
        <extension module="org.jboss.as.jdr"/>
        <extension module="org.jboss.as.jmx"/>
        <extension module="org.jboss.as.jpa"/>
        <extension module="org.jboss.as.jsf"/>
        <extension module="org.jboss.as.jsr77"/>
        <extension module="org.jboss.as.logging"/>
        <extension module="org.jboss.as.mail"/>
        <extension module="org.jboss.as.naming"/>
        <extension module="org.jboss.as.pojo"/>
        <extension module="org.jboss.as.remoting"/>
        <extension module="org.jboss.as.sar"/>
        <extension module="org.jboss.as.security"/>
        <extension module="org.jboss.as.transactions"/>
        <extension module="org.jboss.as.webservices"/>
        <extension module="org.jboss.as.weld"/>
        <extension module="org.wildfly.extension.io"/>
        <extension module="org.wildfly.extension.undertow"/>
    </extensions>
    <management>
        <security-realms>
            <security-realm name="ManagementRealm">
                <authentication>
                    <local default-user="$local" skip-group-loading="true"/>
                    <properties path="mgmt-users.properties" relative-to="jboss.server.config.dir"/>
                </authentication>
                <authorization map-groups-to-roles="false">
                    <properties path="mgmt-groups.properties" relative-to="jboss.server.config.dir"/>
                </authorization>
            </security-realm>
            <security-realm name="ApplicationRealm">
                <authentication>
                    <local default-user="$local" allowed-users="*" skip-group-loading="true"/>
                    <properties path="application-users.properties" relative-to="jboss.server.config.dir"/>
                </authentication>
                <authorization>
                    <properties path="application-groups.properties" relative-to="jboss.server.config.dir"/>
                </authorization>
            </security-realm>
        </security-realms>
        <audit-log>
            <formatters>
                <json-formatter name="json-formatter"/>
            </formatters>
            <handlers>
                <file-handler name="file" formatter="json-formatter" path="audit-log.log" relative-to="jboss.server.data.dir"/>
            </handlers>
            <logger log-boot="true" log-read-only="false" enabled="false">
                <handlers>
                    <handler name="file"/>
                </handlers>
            </logger>
        </audit-log>
        <management-interfaces>
            <http-interface security-realm="ManagementRealm" http-upgrade-enabled="true">
                <socket-binding http="management-http"/>
            </http-interface>
        </management-interfaces>
        <access-control provider="simple">
            <role-mapping>
                <role name="SuperUser">
                    <include>
                        <user name="$local"/>
                    </include>
                </role>
            </role-mapping>
        </access-control>
    </management>
    <profile>
        <subsystem xmlns="urn:jboss:domain:logging:2.0">
            <console-handler name="CONSOLE">
                <level name="INFO"/>
                <formatter>
                    <named-formatter name="COLOR-PATTERN"/>
                </formatter>
            </console-handler>
            <periodic-rotating-file-handler name="FILE" autoflush="true">
                <formatter>
                    <named-formatter name="PATTERN"/>
                </formatter>
                <file relative-to="jboss.server.log.dir" path="server.log"/>
                <suffix value=".yyyy-MM-dd"/>
                <append value="true"/>
            </periodic-rotating-file-handler>
            <logger category="com.arjuna">
                <level name="WARN"/>
            </logger>
            <logger category="org.jboss.as.config">
                <level name="DEBUG"/>
            </logger>
            <logger category="sun.rmi">
                <level name="WARN"/>
            </logger>
            <logger category="jacorb">
                <level name="WARN"/>
            </logger>
            <logger category="jacorb.config">
                <level name="ERROR"/>
            </logger>
            <root-logger>
                <level name="INFO"/>
                <handlers>
                    <handler name="CONSOLE"/>
                    <handler name="FILE"/>
                </handlers>
            </root-logger>
            <formatter name="PATTERN">
                <pattern-formatter pattern="%d{yyyy-MM-dd HH:mm:ss,SSS} %-5p [%c] (%t) %s%e%n"/>
            </formatter>
            <formatter name="COLOR-PATTERN">
                <pattern-formatter pattern="%K{level}%d{HH:mm:ss,SSS} %-5p [%c] (%t) %s%e%n"/>
            </formatter>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:datasources:2.0">
            <datasources>
                <datasource jndi-name="java:jboss/datasources/ExampleDS" pool-name="ExampleDS" enabled="true" use-java-context="true">
                    <connection-url>jdbc:h2:mem:test;DB_CLOSE_DELAY=-1;DB_CLOSE_ON_EXIT=FALSE</connection-url>
                    <driver>h2</driver>
                    <security>
                        <user-name>sa</user-name>
                        <password>sa</password>
                    </security>
                </datasource>
                <drivers>
                    <driver name="h2" module="com.h2database.h2">
                        <xa-datasource-class>org.h2.jdbcx.JdbcDataSource</xa-datasource-class>
                    </driver>
                </drivers>
            </datasources>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:deployment-scanner:2.0">
            <deployment-scanner path="deployments" relative-to="jboss.server.base.dir" scan-interval="5000"/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:ee:2.0">
            <spec-descriptor-property-replacement>false</spec-descriptor-property-replacement>
            <jboss-descriptor-property-replacement>true</jboss-descriptor-property-replacement>
            <annotation-property-replacement>false</annotation-property-replacement>
            <concurrent>
                <context-services>
                    <context-service name="default" jndi-name="java:jboss/ee/concurrency/context/default" use-transaction-setup-provider="true"/>
                </context-services>
                <managed-thread-factories>
                    <managed-thread-factory name="default" jndi-name="java:jboss/ee/concurrency/factory/default" context-service="default"/>
                </managed-thread-factories>
                <managed-executor-services>
                    <managed-executor-service name="default" jndi-name="java:jboss/ee/concurrency/executor/default" context-service="default" hung-task-threshold="60000" core-threads="5" max-threads="25" keepalive-time="5000"/>
                </managed-executor-services>
                <managed-scheduled-executor-services>
                    <managed-scheduled-executor-service name="default" jndi-name="java:jboss/ee/concurrency/scheduler/default" context-service="default" hung-task-threshold="60000" core-threads="2" keepalive-time="3000"/>
                </managed-scheduled-executor-services>
            </concurrent>
            <default-bindings context-service="java:jboss/ee/concurrency/context/default" datasource="java:jboss/datasources/ExampleDS" jms-connection-factory="java:jboss/DefaultJMSConnectionFactory" managed-executor-service="java:jboss/ee/concurrency/executor/default" managed-scheduled-executor-service="java:jboss/ee/concurrency/scheduler/default" managed-thread-factory="java:jboss/ee/concurrency/factory/default"/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:ejb3:2.0">
            <session-bean>
                <stateless>
                    <bean-instance-pool-ref pool-name="slsb-strict-max-pool"/>
                </stateless>
                <stateful default-access-timeout="5000" cache-ref="simple" passivation-disabled-cache-ref="simple"/>
                <singleton default-access-timeout="5000"/>
            </session-bean>
            <default-resource-adapter-name value="${wildfly.ejb.resource-adapter-name:activemq-ra.rar}"/>
            <mdb>
                <resource-adapter-ref resource-adapter-name="${wildfly.ejb.resource-adapter-name:activemq-ra.rar}"/>
                <bean-instance-pool-ref pool-name="mdb-strict-max-pool"/>
            </mdb>
            <pools>
                <bean-instance-pools>
                    <strict-max-pool name="slsb-strict-max-pool" derive-size="from-worker-pools" instance-acquisition-timeout="5" instance-acquisition-timeout-unit="MINUTES"/>
                    <strict-max-pool name="mdb-strict-max-pool" derive-size="from-cpu-count" instance-acquisition-timeout="5" instance-acquisition-timeout-unit="MINUTES"/>
                </bean-instance-pools>
            </pools>
            <caches>
                <cache name="simple"/>
                <cache name="distributable" aliases="passivating clustered" passivation-store-ref="infinispan"/>
            </caches>
            <passivation-stores>
                <passivation-store name="infinispan" cache-container="ejb" max-size="1024"/>
            </passivation-stores>
            <async thread-pool-name="default"/>
            <timer-service thread-pool-name="default" default-data-store="default-file-store">
                <data-stores>
                    <file-data-store name="default-file-store" path="timer-service-data" relative-to="jboss.server.data.dir"/>
                </data-stores>
            </timer-service>
            <remote connector-ref="http-remoting-connector" thread-pool-name="default"/>
            <thread-pools>
                <thread-pool name="default">
                    <max-threads count="10"/>
                    <keepalive-time time="100" unit="milliseconds"/>
                </thread-pool>
            </thread-pools>
            <default-security-domain value="other"/>
            <default-missing-method-permissions-deny-access value="true"/>
            <log-system-exceptions value="true"/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:io:1.0">
            <worker name="default"/>
            <buffer-pool name="default"/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:infinispan:2.0">
            <cache-container name="server" default-cache="default" module="org.wildfly.clustering.server">
                <local-cache name="default"/>
            </cache-container>
            <cache-container name="web" default-cache="passivation" module="org.wildfly.clustering.web.infinispan">
                <local-cache name="passivation">
                    <file-store passivation="true" purge="false"/>
                </local-cache>
            </cache-container>
            <cache-container name="ejb" aliases="sfsb" default-cache="passivation" module="org.wildfly.clustering.ejb.infinispan">
                <local-cache name="passivation">
                    <file-store passivation="true" purge="false"/>
                </local-cache>
            </cache-container>
            <cache-container name="hibernate" default-cache="local-query" module="org.hibernate.infinispan">
                <local-cache name="entity">
                    <transaction mode="NON_XA"/>
                    <eviction strategy="LRU" max-entries="10000"/>
                    <expiration max-idle="100000"/>
                </local-cache>
                <local-cache name="local-query">
                    <eviction strategy="LRU" max-entries="10000"/>
                    <expiration max-idle="100000"/>
                </local-cache>
                <local-cache name="timestamps"/>
            </cache-container>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:jacorb:2.0">
            <orb socket-binding="jacorb" ssl-socket-binding="jacorb-ssl">
                <initializers security="on" transactions="spec"/>
            </orb>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:jaxrs:1.0"/>
        <subsystem xmlns="urn:jboss:domain:jca:2.0">
            <archive-validation enabled="true" fail-on-error="true" fail-on-warn="false"/>
            <bean-validation enabled="true"/>
            <default-workmanager>
                <short-running-threads>
                    <core-threads count="50"/>
                    <queue-length count="50"/>
                    <max-threads count="50"/>
                    <keepalive-time time="10" unit="seconds"/>
                </short-running-threads>
                <long-running-threads>
                    <core-threads count="50"/>
                    <queue-length count="50"/>
                    <max-threads count="50"/>
                    <keepalive-time time="10" unit="seconds"/>
                </long-running-threads>
            </default-workmanager>
            <cached-connection-manager/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:jdr:1.0"/>
        <subsystem xmlns="urn:jboss:domain:jmx:1.3">
            <expose-resolved-model/>
            <expose-expression-model/>
            <remoting-connector/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:jpa:1.1">
            <jpa default-datasource="" default-extended-persistence-inheritance="DEEP"/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:jsf:1.0"/>
        <subsystem xmlns="urn:jboss:domain:jsr77:1.0"/>
        <subsystem xmlns="urn:jboss:domain:mail:2.0">
            <mail-session name="default" jndi-name="java:jboss/mail/Default">
                <smtp-server outbound-socket-binding-ref="mail-smtp"/>
            </mail-session>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:naming:2.0">
            <remote-naming/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:pojo:1.0"/>
        <subsystem xmlns="urn:jboss:domain:remoting:2.0">
            <endpoint/>
            <http-connector name="http-remoting-connector" connector-ref="default" security-realm="ApplicationRealm"/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:sar:1.0"/>
        <subsystem xmlns="urn:jboss:domain:security:1.2">
            <security-domains>
                <security-domain name="other" cache-type="default">
                    <authentication>
                        <login-module code="Remoting" flag="optional">
                            <module-option name="password-stacking" value="useFirstPass"/>
                        </login-module>
                        <login-module code="RealmDirect" flag="required">
                            <module-option name="password-stacking" value="useFirstPass"/>
                        </login-module>
                    </authentication>
                </security-domain>
                <security-domain name="jboss-web-policy" cache-type="default">
                    <authorization>
                        <policy-module code="Delegating" flag="required"/>
                    </authorization>
                </security-domain>
                <security-domain name="jboss-ejb-policy" cache-type="default">
                    <authorization>
                        <policy-module code="Delegating" flag="required"/>
                    </authorization>
                </security-domain>
            </security-domains>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:transactions:2.0">
            <core-environment>
                <process-id>
                    <uuid/>
                </process-id>
            </core-environment>
            <recovery-environment socket-binding="txn-recovery-environment" status-socket-binding="txn-status-manager"/>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:undertow:1.0">
            <buffer-cache name="default"/>
            <server name="default-server">
                <http-listener name="default" socket-binding="http" redirect-socket="https"/>
                <host name="default-host" alias="localhost">
                    <location name="/" handler="welcome-content"/>
                </host>
            </server>
            <servlet-container name="default">
                <jsp-config/>
                <websockets/>
            </servlet-container>
            <handlers>
                <file name="welcome-content" path="${jboss.home.dir}/welcome-content"/>
            </handlers>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:webservices:1.2">
            <wsdl-host>${jboss.bind.address:127.0.0.1}</wsdl-host>
            <endpoint-config name="Standard-Endpoint-Config"/>
            <endpoint-config name="Recording-Endpoint-Config">
                <pre-handler-chain name="recording-handlers" protocol-bindings="##SOAP11_HTTP ##SOAP11_HTTP_MTOM ##SOAP12_HTTP ##SOAP12_HTTP_MTOM">
                    <handler name="RecordingHandler" class="org.jboss.ws.common.invocation.RecordingServerHandler"/>
                </pre-handler-chain>
            </endpoint-config>
        </subsystem>
        <subsystem xmlns="urn:jboss:domain:weld:2.0"/>
    </profile>
    <interfaces>
        <interface name="management">
            <inet-address value="${jboss.bind.address.management:0.0.0.0}"/>
        </interface>
        <interface name="public">
            <inet-address value="${jboss.bind.address:127.0.0.1}"/>
        </interface>
    </interfaces>
    <socket-binding-group name="standard-sockets" default-interface="public" port-offset="${jboss.socket.binding.port-offset:0}">
        <socket-binding name="management-http" interface="management" port="${jboss.management.http.port:9990}"/>
        <socket-binding name="management-https" interface="management" port="${jboss.management.https.port:9993}"/>
        <socket-binding name="ajp" port="${jboss.ajp.port:8009}"/>
        <socket-binding name="http" port="${jboss.http.port:8080}"/>
        <socket-binding name="https" port="${jboss.https.port:8443}"/>
        <socket-binding name="jacorb" interface="unsecure" port="3528"/>
        <socket-binding name="jacorb-ssl" interface="unsecure" port="3529"/>
        <socket-binding name="txn-recovery-environment" port="4712"/>
        <socket-binding name="txn-status-manager" port="4713"/>
        <outbound-socket-binding name="mail-smtp">
            <remote-destination host="localhost" port="25"/>
        </outbound-socket-binding>
    </socket-binding-group>
</server>
EOF'
    
    JAVA_HOME_PATH="/usr/lib/jvm/temurin-8-jdk-amd64"
    sed -i "s|<JAVA_HOME>|${JAVA_HOME_PATH}|g" ${INSTALL_DIR}/wildfly/bin/standalone.conf
    sed -i 's/-Xms64m/-Xms2g/' ${INSTALL_DIR}/wildfly/bin/standalone.conf
    sed -i 's/-Xmx512m/-Xmx4g/' ${INSTALL_DIR}/wildfly/bin/standalone.conf
    
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

    chown -R ${APP_USER}:${APP_USER} "${INSTALL_DIR}"
    
    log "Adicionando usuário de gerenciamento 'admin'"
    ${INSTALL_DIR}/wildfly/bin/add-user.sh admin ${WILDFLY_ADMIN_PASS} --silent
    
    log "Baixando e preparando arquivos da aplicação"
    gdown --id "${SYSTEM_FILE_ID}" -O "${SOURCES_DIR}/sistema.zip"
    gdown --id "${COMPLEMENTARES_FILE_ID}" -O "${SOURCES_DIR}/complementares.zip"
    unzip -o "${SOURCES_DIR}/sistema.zip" -d "${SOURCES_DIR}"
    unzip -o "${SOURCES_DIR}/complementares.zip" -d "${SOURCES_DIR}"

    log "Extraindo módulos e flyway aninhados"
    INNER_MODULES_ZIP="${SOURCES_DIR}/ArquivosComplementares/Modules/aghu-wildfly-modules.zip"
    unzip -o "${INNER_MODULES_ZIP}" -d "${INSTALL_DIR}/wildfly/"
    INNER_FLYWAY_ZIP="${SOURCES_DIR}/drop/aghu-db-migration/target/aghu-db-migration.zip"
    unzip -o "${INNER_FLYWAY_ZIP}" -d "${SOURCES_DIR}/drop/aghu-db-migration/"

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

    export PGPASSWORD=$POSTGRES_OS_PASS
    JBOSS_CLI="${INSTALL_DIR}/wildfly/bin/jboss-cli.sh --connect --user=admin --password=${WILDFLY_ADMIN_PASS}"
    
    log "Configurando DataSource no Wildfly"
    $JBOSS_CLI "/subsystem=datasources/jdbc-driver=postgresql:add(driver-name=postgresql, driver-module-name=org.postgresql, driver-class-name=org.postgresql.Driver)"
    $JBOSS_CLI "data-source add --name=aghuDatasource --jndi-name=java:/aghuDatasource --driver-name=postgresql --connection-url=jdbc:postgresql://127.0.0.1:5432/${DB_NAME} --user-name=ugen_aghu --password=${UGHU_DB_PASS} --validate-on-match=true --min-pool-size=5 --max-pool-size=50"

    log "Restaurando banco de dados"
    log "Verificando se o banco de dados '${DB_NAME}' está pronto para conexões..."
    TIMEOUT=60; START_TIME=$SECONDS
    until psql -h localhost -U ${POSTGRES_USER} -d "${DB_NAME}" -c '\q' &>/dev/null; do
        if (( SECONDS - START_TIME > TIMEOUT )); then echo "ERRO: Tempo limite esperando pelo banco '${DB_NAME}'."; exit 1; fi
        printf "."; sleep 2
    done
    echo -e "\nBanco de dados '${DB_NAME}' está pronto para conexões."
    
    BACKUP_FILE_SOURCE="${SOURCES_DIR}/ArquivosComplementares/Base Zero/dbaghu_aghu1_0.backup"
    BACKUP_FILE_TMP="/tmp/dbaghu_aghu1_0.backup"
    gunzip -f "${BACKUP_FILE_SOURCE}.gz"
    cp "${BACKUP_FILE_SOURCE}" "${BACKUP_FILE_TMP}"
    chown ${POSTGRES_USER}:${POSTGRES_USER} "${BACKUP_FILE_TMP}"
    pg_restore -h localhost -U ${POSTGRES_USER} -d ${DB_NAME} --clean --if-exists "${BACKUP_FILE_TMP}" -v || echo "Avisos do pg_restore ignorados. Continuando..."
    
    log "Redefinindo senhas APÓS o restore para garantir compatibilidade MD5"
    psql -h localhost -U ${POSTGRES_USER} -d ${DB_NAME} <<EOF
ALTER USER postgres WITH PASSWORD '${POSTGRES_OS_PASS}';
ALTER ROLE ugen_aghu WITH PASSWORD '${UGHU_DB_PASS}';
ALTER ROLE ugen_quartz WITH PASSWORD '${QUARTZ_DB_PASS}';
ALTER ROLE ugen_seguranca WITH PASSWORD '${SEGURANCA_DB_PASS}';
EOF

    unset PGPASSWORD
    rm -f "${BACKUP_FILE_TMP}"

    log "Executando migrações do Flyway"
    cd "${SOURCES_DIR}/drop/aghu-db-migration/aghu-db-migration"; chmod +x flyway
    export PGPASSWORD=$POSTGRES_OS_PASS
    ./flyway -user=${POSTGRES_USER} -url=jdbc:postgresql://127.0.0.1:5432/${DB_NAME} -outOfOrder=true migrate
    unset PGPASSWORD
    
    log "Importando menus e perfis de segurança"
    cd "${SOURCES_DIR}/ArquivosComplementares/aghu-seguranca"
    chmod +x seguranca.sh
    export PGPASSWORD=$POSTGRES_OS_PASS
    ./seguranca.sh importar-menu jdbc:postgresql://127.0.0.1:5432/${DB_NAME} ${POSTGRES_USER} "'${POSTGRES_OS_PASS}'"
    ./seguranca.sh importar-seguranca jdbc:postgresql://127.0.0.1:5432/${DB_NAME} ${POSTGRES_USER} "'${POSTGRES_OS_PASS}'"
    unset PGPASSWORD

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
    setup_java8
    setup_database
    setup_ldap
    setup_application
    setup_apache_and_finalize
}

main
