#!/usr/bin/env bash

# Verifica se o script está sendo executado como root
if [ "$(id -u)" -ne 0 ]; then
    echo "Erro: Este script deve ser executado como root."
    exit 1
fi

# Localizar o executável do canary
echo "Procurando o executável do Canary..."
CANARY_PATH=$(find /home -type f -name "canary" -executable 2>/dev/null | head -n 1)

if [ -z "$CANARY_PATH" ]; then
    echo "Erro: Não foi possível encontrar o executável do Canary."
    exit 1
fi

echo "Executável do Canary encontrado em: $CANARY_PATH"

# Obter o diretório do canary e o nome do usuário
CANARY_DIR=$(dirname "$CANARY_PATH")
CANARY_USER=$(stat -c '%U' "$CANARY_PATH")

echo "Diretório do Canary: $CANARY_DIR"
echo "Usuário do Canary: $CANARY_USER"

# Criar o arquivo de serviço
SERVICE_FILE="/etc/systemd/system/canary.service"
echo "Criando o arquivo de serviço em: $SERVICE_FILE"

cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Canary Service
After=network.target

[Service]
User=$CANARY_USER
Group=$CANARY_USER
WorkingDirectory=$CANARY_DIR
ExecStart=$CANARY_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Configurar permissões do arquivo de serviço
chmod 644 "$SERVICE_FILE"
echo "Arquivo de serviço criado com sucesso."

# Recarregar o systemd e habilitar o serviço
echo "Recarregando systemd e habilitando o serviço..."
systemctl daemon-reload
systemctl enable canary.service

# Iniciar o serviço
echo "Iniciando o serviço Canary..."
systemctl start canary.service

# Verificar o status do serviço
echo "Verificando o status do serviço..."
systemctl status canary.service --no-pager

echo "Configuração concluída!"
