#!/bin/bash

# Hardcoded variables
ca_path="./ca"
cert_path="./certs"
config_file="config.ini"

# Functions
function check_and_create_directories {
  mkdir -p $ca_path || { echo "Error creating CA directory"; exit 1; }
  mkdir -p $cert_path || { echo "Error creating certificates directory"; exit 1; }
  touch $config_file || { echo "Error creating configuration file"; exit 1; }
}

function create_ca {
  openssl genrsa -out "${ca_path}/${ca_name}.key" $bit_len || { echo "Error creating CA key"; exit 1; }
  openssl req -new -x509 -days 365 -key "${ca_path}/${ca_name}.key" -out "${ca_path}/${ca_name}.crt" || { echo "Error creating CA certificate"; exit 1; }
  echo "ca_name=${ca_name}" > $config_file
  echo "CA Key: ${ca_path}/${ca_name}.key"
  echo "CA Certificate: ${ca_path}/${ca_name}.crt"
}

function handle_create_ca {
  if [ -f $config_file ]; then
    source $config_file
    if [ ! -z "$ca_name" ]; then
      read -p "CA already exists: ${ca_name}. Do you want to overwrite it? Warning: This will result in the loss of all existing certificates!!! Overwrite? (yes/no): " overwrite
      if [ "$overwrite" != "yes" ]; then
        exit 0
      fi
    else
      echo "No CA found."
    fi
  fi
  read -p "Enter CA name: " ca_name
  while true; do
    read -p "Enter bit length (1024, 2048, 4096): " bit_len
    if [[ "$bit_len" == "1024" || "$bit_len" == "2048" || "$bit_len" == "4096" ]]; then
      break
    else
      echo "Invalid bit length. Please enter 1024, 2048, or 4096."
    fi
  done
  create_ca
}

function create_certificate {
  # Check if CA exists
  if [ ! -f $config_file ] || [ ! -f "${ca_path}/${ca_name}.crt" ] || [ ! -f "${ca_path}/${ca_name}.key" ]; then
    echo "CA does not exist. Do you want to create a CA now? (yes/no)"
    read -p "Option: " create_ca_option
    if [ "$create_ca_option" == "yes" ]; then
      handle_create_ca
    else
      exit 0
    fi
  fi

  # Enter FQDN
  read -p "Enter FQDN: " fqdn

  # Enter bit length
  while true; do
    read -p "Enter bit length (1024, 2048, 4096): " cert_bit_len
    if [[ "$cert_bit_len" == "1024" || "$cert_bit_len" == "2048" || "$cert_bit_len" == "4096" ]]; then
      break
    else
      echo "Invalid bit length. Please enter 1024, 2048, or 4096."
    fi
  done

  # Create directory for certificate
  mkdir -p "${cert_path}/${fqdn}" || { echo "Error creating directory for FQDN"; exit 1; }

  # Create configuration file
  cat <<EOF > "${cert_path}/${fqdn}/${fqdn}.cnf"
[req]
default_bits       = $cert_bit_len
default_md         = sha256
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[req_distinguished_name]
C  = DE
CN = ${fqdn}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${fqdn}
EOF

  # Create key pair and certificate request
  openssl genrsa -out "${cert_path}/${fqdn}/${fqdn}.key" $cert_bit_len || { echo "Error creating certificate key"; exit 1; }
  openssl req -new -key "${cert_path}/${fqdn}/${fqdn}.key" -config "${cert_path}/${fqdn}/${fqdn}.cnf" -out "${cert_path}/${fqdn}/${fqdn}.csr" || { echo "Error creating certificate request"; exit 1; }

  # Sign certificate
  openssl x509 -req -days 365 -in "${cert_path}/${fqdn}/${fqdn}.csr" -CA "${ca_path}/${ca_name}.crt" -CAkey "${ca_path}/${ca_name}.key" -CAcreateserial -out "${cert_path}/${fqdn}/${fqdn}.crt" -extensions v3_req -extfile "${cert_path}/${fqdn}/${fqdn}.cnf" || { echo "Error signing certificate"; exit 1; }

  # Create fullchain certificate
  cat "${cert_path}/${fqdn}/${fqdn}.crt" "${ca_path}/${ca_name}.crt" > "${cert_path}/${fqdn}/${fqdn}.fullchain.crt"

  # Generate password for PKCS - P12
  password=$(openssl rand -base64 32)
  echo "$password" > "${cert_path}/${fqdn}/p12_pkcs_password.key"
  chmod 600 "${cert_path}/${fqdn}/p12_pkcs_password.key"

  # Create PKCS#12 certificate with key and cert
  openssl pkcs12 -export -out "${cert_path}/${fqdn}/${fqdn}.p12" -inkey "${cert_path}/${fqdn}/${fqdn}.key" -in "${cert_path}/${fqdn}/${fqdn}.crt" -certfile "${ca_path}/${ca_name}.crt" -passout pass:"$password"

  # Optionally, create PKCS#12 with fullchain
  openssl pkcs12 -export -out "${cert_path}/${fqdn}/${fqdn}_fullchain.p12" -inkey "${cert_path}/${fqdn}/${fqdn}.key" -in "${cert_path}/${fqdn}/${fqdn}.fullchain.crt" -passout pass:"$password"


  # Display paths of certificates and keys
  echo "Certificate key: ${cert_path}/${fqdn}/${fqdn}.key"
  echo "Certificate request: ${cert_path}/${fqdn}/${fqdn}.csr"
  echo "Certificate: ${cert_path}/${fqdn}/${fqdn}.crt"
  echo "Fullchain certificate: ${cert_path}/${fqdn}/${fqdn}.fullchain.crt"
  echo "Generated password: $password"
  echo "PKCS-#12-File: ${cert_path}/${fqdn}/${fqdn}.p12"
  echo "Fullchain PKCS-#12-File: ${cert_path}/${fqdn}/${fqdn}_fullchain.p12"
}

# Initial check and create directories
check_and_create_directories

# Check if CA exists
if [ -f $config_file ]; then
  source $config_file
  if [ ! -z "$ca_name" ]; then
    echo "CA exists: ${ca_name}"
  else
    echo "No CA found."
  fi
else
  echo "No CA found."
fi

# Main menu
echo "Choose an option:"
echo "1. Create CA"
echo "2. Create Certificate"

read -p "Option (1/2): " option

case $option in
  1)
    echo "Create CA selected."
    handle_create_ca
    ;;
  2)
    echo "Create Certificate selected."
    source $config_file
    create_certificate
    ;;
  *)
    echo "Invalid option."
    ;;
esac

