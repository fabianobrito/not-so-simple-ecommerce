#!/bin/bash
password="@DevOpsNaNuvem$%!"
days=365
keysize=4096

# Detect the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$(cd "$(dirname "${SCRIPT_DIR}")/certificates" && pwd)"

# Verify certificates directory exists
if [ ! -d "$CERT_DIR" ]; then
    echo "Error: Certificates directory not found at $CERT_DIR"
    exit 1
fi

# ============================================================================
# Gera a Autoridade Certificadora (CA) raiz
# ============================================================================
# A CA raiz é a base de confiança de toda a cadeia de certificados.
#
#    IMPORTANTE: Este é um certificado SELF-SIGNED (AUTO-ASSINADO)
#    para DESENVOLVIMENTO/TESTE, NÃO é um certificado de CA pública (como Let's Encrypt)
#
# Arquivos gerados:
# 1. root-ca.key - Chave PRIVADA da CA (NUNCA compartilhar!)
#    Guardado por: SERVIDOR (a máquina física/VM onde o projeto está rodando)
#       Explicação: Não é nos pods (Nginx, Kestrel), é no HOST/SERVIDOR
#                   onde os containers estão sendo executados
#                   Ex: seu laptop, servidor Linux, VM na nuvem, etc.
#    Usada para: Assinar certificados dos servidores (Nginx)
#       CRÍTICO: Se vazar, a segurança de toda a cadeia é comprometida!
#
# 2. root-ca.crt - Certificado PÚBLICO da CA
#    Guardado por: CADA CLIENTE/NAVEGADOR que acessa a aplicação
#       Explicação: Cada desenvolvedor/testador precisa:
#                   1. Baixar o arquivo root-ca.crt
#                   2. Importar no navegador como "Autoridade Confiável"
#                   Após isso, o navegador confia em certificados assinados por esta CA
#       Diferente de: Certificados públicos da Let's Encrypt que já vêm confiáveis
#
#   Fluxo:
# - Em DESENVOLVIMENTO: Todos baixam root-ca.crt e importam no navegador
# - Em PRODUÇÃO: Você usaria Let's Encrypt ou outro CA público
#   (não precisaria importar nada no navegador dos usuários)
# ============================================================================
function generate_CA_certificates() {
    if [ ! -f "$CERT_DIR/root-ca.key" ]; then
        echo "Generating root CA private key..."
        openssl genrsa \
            -des3 \
            -passout "pass:$password" \
            -out "$CERT_DIR/root-ca.key" \
            "$keysize"
    else
        echo "Root CA private key already exists. Skipping generation."
    fi

    if [ -f "$CERT_DIR/root-ca.key" ] \
        && [ ! -f "$CERT_DIR/root-ca.crt" ]; then

        echo "Generating root CA certificate..."
        openssl req \
            -x509 \
            -new \
            -key "$CERT_DIR/root-ca.key" \
            -passin "pass:$password" \
            -days "$days" \
            -sha256 \
            -out "$CERT_DIR/root-ca.crt" \
            -subj /CN=devopsnanuvem.internal
    else
        echo "Root CA certificate already exists. Skipping generation."
    fi
}

# ============================================================================
# Gera uma Solicitação de Assinatura de Certificado (CSR)
# ============================================================================
# CSR é uma solicitação que será enviada à CA para ser assinada.
# Este é um arquivo INTERMEDIÁRIO no processo.
#
# Arquivos gerados:
# 1. signing-request.key - Chave PRIVADA do servidor (Nginx + Kestrel)
#    Usado por: Kestrel (dentro do container .NET)
#    Armazenada com segurança e usada para descriptografar dados HTTPS
#       Fica no HOST mas é copiada para dentro do container via volume
#       NUNCA deve ser compartilhado ou exposto!
#
# 2. signing-request.csr - Solicitação para assinar
#    Localização: ./certificates/signing-request.csr (no HOST)
#    Guardado por: Ninguém (arquivo intermediário, pode ser descartado após uso)
#    Contém: informações do servidor e chave PÚBLICA
#    Será enviada para a CA assinar e validar
#
#   Fluxo:
#   1. Este CSR é assinado pela CA (root-ca.key que está no HOST)
#   2. Resultado: nginx-certificate.crt (certificado assinado para o navegador)
#   3. Depois convertido para: kestrel-certificate.pfx (para uso do .NET)
# ============================================================================
function generate_certificate_signing_request() {
    if [ ! -f "$CERT_DIR/signing-request.key" ] \
        && [ ! -f "$CERT_DIR/signing-request.csr" ]; then

        echo "Generating certificate signing request..."
        openssl req \
            -new \
            -noenc \
            -newkey "rsa:$keysize" \
            -keyout "$CERT_DIR/signing-request.key" \
            -out "$CERT_DIR/signing-request.csr" \
            -subj /CN=devopsnanuvem.internal
    else
        echo "Certificate signing request already exists. Skipping generation."
    fi
}

# ============================================================================
# Gera o certificado do Nginx (proxy reverso)
# ============================================================================
# Este é o certificado FINAL apresentado ao BROWSER do cliente!
# Criado assinando o CSR com a chave privada da CA.
#
# Arquivo gerado:
# - nginx-certificate.crt: Certificado que Nginx apresenta para HTTPS
#   Guardado por: SERVIDOR/HOST (máquina onde o projeto está)
#   Montado em: Container Nginx via volume Docker
#   Visto por: NAVEGADOR do cliente (quando acessa https://seu-dominio)
#      Fica no HOST mas é compartilhado com Nginx via docker-compose volumes
#
#   Processo:
# 1. Pega o CSR (signing-request.csr) gerado anteriormente
# 2. Assina com root-ca.key (chave privada da CA no HOST)
# 3. Gera nginx-certificate.crt (certificado assinado)
#
#   Cadeia de confiança no navegador:
#   Navegador recebe: nginx-certificate.crt (do container Nginx)
#              ↓
#   Valida a assinatura usando: root-ca.crt (já confiável no navegador)
#              ↓
#     Certificado válido e seguro!
#
# IMPORTANTE: Precisa que root-ca.crt esteja instalado no navegador
#             caso contrário mostrará aviso de "certificado não confiável"
# ============================================================================
function generate_nginx_certificate() {
    if [ -f "$CERT_DIR/signing-request.csr" ] \
        && [ -f "$CERT_DIR/root-ca.crt" ] \
        && [ -f "$CERT_DIR/config.ext" ] \
        && [ ! -f "$CERT_DIR/nginx-certificate.crt" ]; then

        echo "Generating nginx certificate..."
        openssl x509 \
            -req \
            -in "$CERT_DIR/signing-request.csr" \
            -CA "$CERT_DIR/root-ca.crt" \
            -CAkey "$CERT_DIR/root-ca.key" \
            -passin "pass:$password" \
            -sha256 \
            -CAcreateserial \
            -days "$days" \
            -extfile "$CERT_DIR/config.ext" \
            -out "$CERT_DIR/nginx-certificate.crt"
    else
        echo "Nginx certificate already exists. Skipping generation."
    fi
}

# ============================================================================
# Gera o certificado do Kestrel (.NET runtime)
# ============================================================================
# Kestrel é o servidor web que roda as aplicações .NET (igual Tomcat no Spring).
# Este passo converte o certificado Nginx para formato que .NET entende.
#
# Arquivo gerado:
# - kestrel-certificate.pfx: Certificado em formato que .NET utiliza
#   Guardado por: SERVIDOR/HOST (máquina onde o projeto está)
#   Montado em: Container Kestrel (.NET) via volume Docker
#   Acessado por: Apenas a aplicação .NET dentro do container (INTERNO)
#      Fica no HOST mas é compartilhado com .NET via docker-compose volumes
#   Contém: Chave privada + Certificado em um único arquivo protegido
#
#   Processo:
# 1. Pega: signing-request.key (chave privada) + nginx-certificate.crt
# 2. Converte para formato PKCS#12 (.pfx)
# 3. Protege com senha para uso seguro
#
#   Uso interno:
# Kestrel, ao receber requisição HTTPS, usa este certificado para:
#   1. Descriptografar a requisição (usando a chave privada)
#   2. Verificar a identidade perante o Nginx
#   3. Estabelecer conexão HTTPS segura entre Nginx ↔ Kestrel
#
# Obs: Este certificado é INTERNO (entre Nginx e Kestrel containers)
#      O navegador NUNCA vê este arquivo, vê apenas nginx-certificate.crt
# ============================================================================
function generate_kestrol_certificate() {
    if [ -f "$CERT_DIR/signing-request.key" ] \
        && [ -f "$CERT_DIR/nginx-certificate.crt" ] \
        && [ ! -f "$CERT_DIR/kestrel-certificate.pfx" ]; then

        echo "Generating kestrel certificate..."
        openssl pkcs12 \
            -inkey "$CERT_DIR/signing-request.key" \
            -in "$CERT_DIR/nginx-certificate.crt" \
            -export \
            -out "$CERT_DIR/kestrel-certificate.pfx" \
            -passout "pass:$password"
    else
        echo "Kestrel certificate already exists. Skipping generation."
    fi
}

# ============================================================================
# Execução das funções na ordem correta
# ============================================================================
generate_CA_certificates
generate_certificate_signing_request
generate_nginx_certificate
generate_kestrol_certificate
