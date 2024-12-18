#!/usr/bin/env bash

# Verificar se o script está sendo executado como root
if [ "$(id -u)" -eq 0 ]; then
    echo "Erro: Este script não pode ser executado como root ou com sudo."
    echo "Por favor, execute como um usuário normal."
    exit 1
fi

# Variáveis que necessitam de alteração
MYSQL_USER="SEU_USUARIO"
MYSQL_USER_PASSWORD="SUA_SENHA"
MYSQL_ROOT_PASSWORD="SUA_SENHA_ROOT"
MYSQL_DATABASE="NOME_BANCO"
EMAIL="SEU_EMAIL"
TIMEZONE="America/Sao_Paulo"

# Variáveis de versões
PHP_VERSION="8.2"
PHPMYADMIN_VERSION="5.2.1"
BLOWFISH_SECRET=$(openssl rand -base64 24 | sed 's/[\/&]/\\&/g')

# Variáveis de caminhos
WWW_DIR="/var/www/html"
HOME_DIR="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
CANARY_DIR="${HOME_DIR}/canary"
MYACC_DIR="${HOME_DIR}/myacc"
VCPKG_DIR="${HOME_DIR}/vcpkg"

# Variáveis de pacotes
PHP_PACKAGES="php${PHP_VERSION} php${PHP_VERSION}-cli php${PHP_VERSION}-curl php${PHP_VERSION}-fpm \
              php${PHP_VERSION}-gd php${PHP_VERSION}-mysql php${PHP_VERSION}-xml php${PHP_VERSION}-zip \
              php${PHP_VERSION}-bcmath php${PHP_VERSION}-mbstring php${PHP_VERSION}-calendar"
DB_PACKAGES="mariadb-server mariadb-client"
DEV_PACKAGES="git cmake build-essential autoconf libtool ca-certificates curl zip unzip tar pkg-config ninja-build ccache gcc-14 g++-14"
SYSTEM_PACKAGES="ufw acl snapd software-properties-common apt-transport-https python3-launchpadlib nginx linux-headers-$(uname -r)"

# Funções
add_repositories() {
    REPO="ppa:ondrej/php"
    if ! grep -q "^deb .*$REPO" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo "Repositório $REPO ainda não adicionado. Adicionando agora..."
        sudo add-apt-repository "$REPO" -y
    fi
}

install_packages() {
    sudo apt-get update && sudo apt-get upgrade -y
    sudo apt-get install -y $@
}

update_cmake() {
    # Versão mínima desejada do cmake
    local MINIMUM_VERSION="3.20.0"

    # Verificar se o cmake está instalado
    if command -v cmake > /dev/null 2>&1; then
        # Obter a versão atual do cmake
        local CURRENT_VERSION
        CURRENT_VERSION=$(cmake --version | head -n 1 | awk '{print $3}')

        # Comparar as versões
        if dpkg --compare-versions "$CURRENT_VERSION" ge "$MINIMUM_VERSION"; then
            echo "CMake já está instalado e atualizado (versão: $CURRENT_VERSION). Nenhuma ação necessária."
            return 0
        else
            echo "Versão do CMake desatualizada ($CURRENT_VERSION). Atualizando para uma versão mais recente..."
        fi
    else
        echo "CMake não está instalado. Instalando..."
    fi

    # Realizar a atualização
    sudo apt-get remove --purge cmake -y
    hash -r
    sudo snap install cmake --classic

    # Verificar se a instalação foi bem-sucedida
    if command -v cmake > /dev/null 2>&1; then
        echo "CMake atualizado com sucesso para a versão $(cmake --version | head -n 1 | awk '{print $3}')."
    else
        echo "Erro: não foi possível instalar ou atualizar o CMake."
        return 1
    fi
}

update_gcc() {
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-14 100 --slave /usr/bin/g++ g++ /usr/bin/g++-14 --slave /usr/bin/gcov gcov /usr/bin/gcov-14
    sudo update-alternatives --set gcc /usr/bin/gcc-14
}

mysql_secure_setup() {
    # Verificar se o MySQL está acessível
    if ! sudo mysqladmin ping > /dev/null 2>&1; then
        echo "Erro: O servidor MySQL não está em execução."
        return 1
    fi

    # Verificar se a senha do root já está configurada
    if sudo mysql --user=root --batch --skip-column-names -e "SELECT 1 FROM mysql.user WHERE User='root' AND Host='localhost' AND authentication_string != '';" | grep -q 1; then
        echo "Senha do usuário 'root' já configurada. Nenhuma ação necessária."
    else
        echo "Configurando senha para o usuário 'root'..."
        sudo mysql --user=root --batch <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
EOF
    fi

    # Verificar e excluir usuários indesejados
    if sudo mysql --user=root --batch --skip-column-names -e "SELECT COUNT(*) FROM mysql.user WHERE User='';" | grep -qv 0; then
        echo "Removendo usuários anônimos..."
        sudo mysql --user=root --batch <<EOF
DELETE FROM mysql.user WHERE User='';
EOF
    else
        echo "Nenhum usuário anônimo encontrado."
    fi

    if sudo mysql --user=root --batch --skip-column-names -e "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" | grep -qv 0; then
        echo "Removendo acessos remotos do usuário 'root'..."
        sudo mysql --user=root --batch <<EOF
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
EOF
    else
        echo "Nenhum acesso remoto para o usuário 'root' encontrado."
    fi

    # Verificar e excluir o banco de dados de teste
    if sudo mysql --user=root --batch --skip-column-names -e "SHOW DATABASES LIKE 'test';" | grep -q test; then
        echo "Removendo banco de dados 'test'..."
        sudo mysql --user=root --batch <<EOF
DROP DATABASE IF EXISTS test;
EOF
    else
        echo "Banco de dados 'test' não encontrado."
    fi

    # Verificar e excluir permissões do banco de dados de teste
    if sudo mysql --user=root --batch --skip-column-names -e "SELECT COUNT(*) FROM mysql.db WHERE Db='test' OR Db LIKE 'test\\_%';" | grep -qv 0; then
        echo "Removendo permissões para o banco de dados 'test'..."
        sudo mysql --user=root --batch <<EOF
DELETE FROM mysql.db WHERE Db='test' OR Db LIKE 'test\\_%';
EOF
    else
        echo "Nenhuma permissão para o banco de dados 'test' encontrada."
    fi

    # Atualizar privilégios se alterações foram feitas
    echo "Atualizando privilégios..."
    sudo mysql --user=root --batch <<EOF
FLUSH PRIVILEGES;
EOF

    echo "Configuração do MySQL concluída com sucesso."
}

setup_mysql_user() {
    # Verificar se o MySQL está acessível
    if ! sudo mysqladmin ping > /dev/null 2>&1; then
        echo "Erro: O servidor MySQL não está em execução."
        return 1
    fi

    # Verificar se o usuário já existe
    if sudo mysql --user=root --password=${MYSQL_ROOT_PASSWORD} --batch --skip-column-names -e "SELECT 1 FROM mysql.user WHERE user='${MYSQL_USER}' AND host='localhost';" | grep -q 1; then
        echo "O usuário '${MYSQL_USER}' já existe. Verificando permissões..."
        
        # Verificar se o usuário já possui as permissões necessárias
        local CURRENT_PRIVILEGES
        CURRENT_PRIVILEGES=$(sudo mysql --user=root --password=${MYSQL_ROOT_PASSWORD} --batch --skip-column-names -e "SHOW GRANTS FOR '${MYSQL_USER}'@'localhost';")

        if echo "$CURRENT_PRIVILEGES" | grep -q "GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION"; then
            echo "O usuário '${MYSQL_USER}' já possui as permissões necessárias. Nenhuma ação necessária."
            return 0
        else
            echo "Atualizando permissões para o usuário '${MYSQL_USER}'..."
            sudo mysql --user=root --password=${MYSQL_ROOT_PASSWORD} <<EOF
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
        fi
    else
        echo "Criando o usuário '${MYSQL_USER}' e configurando permissões..."
        sudo mysql --user=root --password=${MYSQL_ROOT_PASSWORD} <<EOF
CREATE USER '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_USER_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
    fi

    echo "Configuração do usuário MySQL concluída com sucesso."
}

configure_nginx() {
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo tee /etc/nginx/conf.d/default.conf > /dev/null <<EOL
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root ${WWW_DIR};
    index index.html index.php;

    server_name _;

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

    sudo systemctl enable nginx && sudo systemctl reload nginx > /dev/null 2>&1
}

configure_phpmyadmin() {
    # Validar variáveis essenciais
    if [[ -z "$PHPMYADMIN_VERSION" || -z "$WWW_DIR" || -z "$BLOWFISH_SECRET" ]]; then
        echo "Erro: PHPMYADMIN_VERSION, WWW_DIR ou BLOWFISH_SECRET não definidos."
        return 1
    fi

    # Verificar se o phpMyAdmin já está instalado
    if [[ -d "${WWW_DIR}/phpmyadmin" ]]; then
        echo "phpMyAdmin já está configurado em ${WWW_DIR}/phpmyadmin. Nenhuma ação necessária."
        return 0
    fi

    local TMP_DIR="${HOME_DIR}/phpmyadmin_temp"
    local ZIP_FILE="${TMP_DIR}/phpmyadmin.zip"

    # Criar diretório temporário
    mkdir -p "$TMP_DIR"

    # Baixar phpMyAdmin
    echo "Baixando phpMyAdmin versão $PHPMYADMIN_VERSION..."
    if ! wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}/phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.zip" -O "$ZIP_FILE"; then
        echo "Erro ao baixar phpMyAdmin."
        return 1
    fi

    # Extrair arquivo baixado
    echo "Extraindo phpMyAdmin..."
    if ! unzip -q "$ZIP_FILE" -d "$TMP_DIR"; then
        echo "Erro ao extrair phpMyAdmin."
        return 1
    fi

    # Mover para o diretório correto
    local EXTRACTED_DIR
    EXTRACTED_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "phpMyAdmin-*")
    if [[ -z "$EXTRACTED_DIR" ]]; then
        echo "Erro: Diretório extraído do phpMyAdmin não encontrado."
        return 1
    fi

    sudo mv "$EXTRACTED_DIR" "${WWW_DIR}/phpmyadmin"
    sudo rm -rf "$TMP_DIR"

    # Ajustar permissões
    echo "Configurando permissões..."
    sudo chown -R www-data:www-data "${WWW_DIR}/phpmyadmin"
    sudo chmod -R 775 "${WWW_DIR}/phpmyadmin"

    # Configurar arquivo de configuração
    local CONFIG_FILE="${WWW_DIR}/phpmyadmin/config.inc.php"
    local SAMPLE_CONFIG_FILE="${WWW_DIR}/phpmyadmin/config.sample.inc.php"

    if [[ -f "$SAMPLE_CONFIG_FILE" && ! -f "$CONFIG_FILE" ]]; then
        echo "Arquivo config.inc.php não encontrado. Copiando config.sample.inc.php..."
        sudo cp "$SAMPLE_CONFIG_FILE" "$CONFIG_FILE"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        if ! grep -q "^\$cfg\['blowfish_secret'\] = '${BLOWFISH_SECRET}';" "$CONFIG_FILE"; then
            echo "Atualizando blowfish_secret no config.inc.php..."
            sudo sed -i "s#^\$cfg\['blowfish_secret'\] = .*;#\$cfg\['blowfish_secret'\] = '${BLOWFISH_SECRET}';#" "$CONFIG_FILE"
        else
            echo "blowfish_secret já está configurado corretamente."
        fi
    else
        echo "Erro: config.inc.php não encontrado após tentativa de cópia."
        return 1
    fi

    echo "Configuração do phpMyAdmin concluída com sucesso."
}

clone_repositories() {
    # Clona e executa o vcpkg
    # Verifica se o diretório já existe
    if [ ! -d "$VCPKG_DIR" ]; then
        # Se o diretório não existir, clona o repositório
        git clone https://github.com/microsoft/vcpkg.git ${VCPKG_DIR}
    else
        # Se o diretório existir, faz um pull para garantir que está atualizado
        cd ${VCPKG_DIR}
        git pull
    fi

    # Executa o bootstrap
    ${VCPKG_DIR}/bootstrap-vcpkg.sh



    # Verifica se o diretório CANARY_DIR já existe
    if [ ! -d "$CANARY_DIR" ]; then
        # Se o diretório não existir, clona o repositório
        git clone --depth 1 https://github.com/opentibiabr/canary.git ${CANARY_DIR}
    else
        # Se o diretório existir, faz um pull para garantir que está atualizado
        cd ${CANARY_DIR}
        git pull
    fi

    # Define as permissões
    sudo setfacl -R -m g:www-data:rx ${HOME_DIR}
    sudo setfacl -R -m g:www-data:rx ${CANARY_DIR}
    sudo chmod -R 775 ${CANARY_DIR}

    # Configura o repositório e executa o build
    cd ${CANARY_DIR}

    if [ -f "${CANARY_DIR}/config.lua.dist" ]; then
        mv "${CANARY_DIR}/config.lua.dist" "${CANARY_DIR}/config.lua"
    fi

    # Verifica se o diretório canary existe antes de prosseguir
    if [ -d "${CANARY_DIR}" ]; then
        mkdir -p ${CANARY_DIR}/build

        # Verifica se o arquivo cmake existe para evitar erros
        if [ -f "${CANARY_DIR}/CMakeLists.txt" ]; then
            cd ${CANARY_DIR}/build
            cmake -DCMAKE_TOOLCHAIN_FILE=~/vcpkg/scripts/buildsystems/vcpkg.cmake .. --preset linux-release
            cmake --build linux-release

            # Verifica se o binário canary foi gerado antes de copiá-lo
            if [ -f "${CANARY_DIR}/build/linux-release/bin/canary" ]; then
                cp -r ${CANARY_DIR}/build/linux-release/bin/canary ${CANARY_DIR}
                sudo chmod +x ${CANARY_DIR}/canary
            else
                echo "Falha: o binário 'canary' não foi gerado."
            fi
        else
            echo "Falha: o arquivo CMakeLists.txt não foi encontrado no diretório ${CANARY_DIR}."
        fi
    else
        echo "Falha: o diretório ${CANARY_DIR} não foi encontrado."
    fi

    # Verifica se as configurações do banco já estão corretas antes de executar os comandos sed
    if ! grep -q "mysqlUser = \"${MYSQL_USER}\"" "${CANARY_DIR}/config.lua"; then
        sudo sed -i "s|mysqlUser = \"root\"|mysqlUser = \"${MYSQL_USER}\"|g" "${CANARY_DIR}/config.lua"
    fi

    if ! grep -q "mysqlPass = \"${MYSQL_USER_PASSWORD}\"" "${CANARY_DIR}/config.lua"; then
        sudo sed -i "s|mysqlPass = \"root\"|mysqlPass = \"${MYSQL_USER_PASSWORD}\"|g" "${CANARY_DIR}/config.lua"
    fi

    if ! grep -q "mysqlDatabase = \"${MYSQL_DATABASE}\"" "${CANARY_DIR}/config.lua"; then
        sudo sed -i "s|mysqlDatabase = \"otservbr-global\"|mysqlDatabase = \"${MYSQL_DATABASE}\"|g" "${CANARY_DIR}/config.lua"
    fi



    # Verifica se o diretório MYACC_DIR já existe
    if [ ! -d "$MYACC_DIR" ]; then
        # Se o diretório não existir, clona o repositório
        git clone https://github.com/opentibiabr/myaac.git ${MYACC_DIR}
    else
        # Se o diretório existir, faz um pull para garantir que está atualizado
        cd ${MYACC_DIR}
        git pull
    fi

    # Move os arquivos do MYACC_DIR para o diretório WWW_DIR e configura permissões
    sudo mv ${MYACC_DIR}/* ${WWW_DIR}
    sudo rm -rf ${MYACC_DIR}
    sudo chown -R www-data:www-data ${WWW_DIR}
    sudo chmod -R 775 ${WWW_DIR} && sudo chmod -R 775 ${WWW_DIR}/system ${WWW_DIR}/images ${WWW_DIR}/plugins ${WWW_DIR}/tools

    # Verifica se o 'server_path' já está configurado corretamente antes de executar o sed
    if ! grep -q "'server_path' => '${CANARY_DIR}'" "${WWW_DIR}/config.php"; then
        sudo sed -i "s|'server_path' => ''|'server_path' => '${CANARY_DIR}'|g" "${WWW_DIR}/config.php"
    fi
}

setup_database() {
    # Verifica se o arquivo schema.sql existe
    if [[ ! -f "$CANARY_DIR/schema.sql" ]]; then
        echo "Erro: Arquivo $CANARY_DIR/schema.sql não encontrado!"
        exit 1
    fi

    # Verifica se o banco de dados já existe
    if sudo mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" --batch --skip-column-names -e "SHOW DATABASES LIKE '${MYSQL_DATABASE}';" | grep -q "${MYSQL_DATABASE}"; then
        echo "O banco de dados '${MYSQL_DATABASE}' já existe."
    else
        echo "Criando o banco de dados '${MYSQL_DATABASE}'..."
        sudo mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" <<EOF
CREATE DATABASE ${MYSQL_DATABASE};
EOF
    fi

    # Verifica se o schema já foi aplicado
    local TABLE_COUNT
    TABLE_COUNT=$(sudo mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" --batch --skip-column-names -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}';")
    if [[ "$TABLE_COUNT" -gt 0 ]]; then
        echo "O banco de dados '${MYSQL_DATABASE}' já possui tabelas. Nenhuma ação necessária para o schema."
    else
        echo "Aplicando o schema para o banco de dados '${MYSQL_DATABASE}'..."
        sudo mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" ${MYSQL_DATABASE} < "$CANARY_DIR/schema.sql"
    fi

    echo "Configuração do banco de dados concluída com sucesso."
}

setup_firewall() {
    # Função para verificar e adicionar regras somente se necessário
    add_firewall_rule() {
        local RULE="$1"
        if ! sudo ufw status | grep -q "$RULE"; then
            echo "Adicionando regra de firewall: $RULE"
            sudo ufw allow "$RULE"
        else
            echo "Regra de firewall já configurada: $RULE"
        fi
    }

    # Adicionar regras necessárias
    add_firewall_rule "Nginx Full"
    add_firewall_rule "22/tcp"
    add_firewall_rule "7171/tcp"
    add_firewall_rule "7172/tcp"
    add_firewall_rule "8245/tcp"

    # Ativar e recarregar o firewall apenas se necessário
    if ! sudo ufw status | grep -q "Status: active"; then
        echo "Ativando o firewall..."
        sudo ufw --force enable
    else
        echo "O firewall já está ativado."
    fi

    echo "Recarregando o firewall..."
    sudo ufw reload

    echo "Configuração do firewall concluída com sucesso."
}

# Execução do Script
add_repositories
install_packages $PHP_PACKAGES $DB_PACKAGES $DEV_PACKAGES $SYSTEM_PACKAGES
update_cmake
update_gcc
mysql_secure_setup
setup_mysql_user
configure_nginx
configure_phpmyadmin
clone_repositories
setup_database
setup_firewall

# Reiniciando serviços
sudo systemctl restart nginx > /dev/null 2>&1
sudo systemctl enable php${PHP_VERSION}-fpm && sudo systemctl restart php${PHP_VERSION}-fpm > /dev/null 2>&1

# Finalizando o script
echo
echo
echo -e "\033[1;32m[$(date +'%d/%m/%Y %H:%M')] Instalação concluída com sucesso!\033[0m"
echo
echo

# Obtém o IP local da máquina
IP_LOCAL=$(hostname -I | awk '{print $1}')

echo "Para acessar o phpMyAdmin, acesse: http://${IP_LOCAL}/phpmyadmin"
echo
echo "Finalize a instalação do myACC acessando: http://${IP_LOCAL}/install"
echo
echo "Após a instalação, remova o diretório de instalação para maior segurança."
echo "Utilize o comando => mv ${WWW_DIR}/install ${WWW_DIR}/install_disabled-$(date +'%d%m%Y%H%M')"
