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
  read -p "Enter validity of CA certificate in years: " validity_years
  validity_days=$((validity_years * 365))

  openssl genrsa -out "${ca_path}/${ca_name}.key" $bit_len || { echo "Error creating CA key"; exit 1; }
  openssl req -new -x509 -days $validity_days -key "${ca_path}/${ca_name}.key" -out "${ca_path}/${ca_name}.crt" || { echo "Error creating CA certificate"; exit 1; }
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
  if [ ! -f $config_file ]; then
    echo "CA does not exist. Do you want to create a CA now? (yes/no)"
    read -p "Option: " create_ca_option
    if [ "$create_ca_option" == "yes" ]; then
      handle_create_ca
    else
      exit 0
    fi
  fi

  source $config_file

  read -p "Enter FQDN: " fqdn

  while true; do
    read -p "Enter bit length (1024, 2048, 4096): " cert_bit_len
    if [[ "$cert_bit_len" == "1024" || "$cert_bit_len" == "2048" || "$cert_bit_len" == "4096" ]]; then
      break
    else
      echo "Invalid bit length. Please enter 1024, 2048, or 4096."
    fi
  done

  mkdir -p "${cert_path}/${fqdn}" || { echo "Error creating directory for FQDN"; exit 1; }

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

  openssl genrsa -out "${cert_path}/${fqdn}/${fqdn}.key" $cert_bit_len || { echo "Error creating certificate key"; exit 1; }
  openssl req -new -key "${cert_path}/${fqdn}/${fqdn}.key" -config "${cert_path}/${fqdn}/${fqdn}.cnf" -out "${cert_path}/${fqdn}/${fqdn}.csr" || { echo "Error creating certificate request"; exit 1; }

  read -p "Enter validity of certificate in years: " validity_years
  validity_days=$((validity_years * 365))

  openssl x509 -req -days $validity_days -in "${cert_path}/${fqdn}/${fqdn}.csr" -CA "${ca_path}/${ca_name}.crt" -CAkey "${ca_path}/${ca_name}.key" -CAcreateserial -out "${cert_path}/${fqdn}/${fqdn}.crt" -extensions v3_req -extfile "${cert_path}/${fqdn}/${fqdn}.cnf" || { echo "Error signing certificate"; exit 1; }

  cat "${cert_path}/${fqdn}/${fqdn}.crt" "${ca_path}/${ca_name}.crt" > "${cert_path}/${fqdn}/${fqdn}.fullchain.crt"

  password=$(openssl rand -base64 32)
  echo "$password" > "${cert_path}/${fqdn}/p12_pkcs_password.key"
  chmod 600 "${cert_path}/${fqdn}/p12_pkcs_password.key"

  openssl pkcs12 -export -out "${cert_path}/${fqdn}/${fqdn}.p12" -inkey "${cert_path}/${fqdn}/${fqdn}.key" -in "${cert_path}/${fqdn}/${fqdn}.crt" -certfile "${ca_path}/${ca_name}.crt" -passout pass:"$password"
  openssl pkcs12 -export -out "${cert_path}/${fqdn}/${fqdn}_fullchain.p12" -inkey "${cert_path}/${fqdn}/${fqdn}.key" -in "${cert_path}/${fqdn}/${fqdn}.fullchain.crt" -passout pass:"$password"

  cat "${cert_path}/${fqdn}/${fqdn}.key" "${cert_path}/${fqdn}/${fqdn}.crt" > "${cert_path}/${fqdn}/${fqdn}.pem"
  cat "${cert_path}/${fqdn}/${fqdn}.key" "${cert_path}/${fqdn}/${fqdn}.crt" "${ca_path}/${ca_name}.crt" > "${cert_path}/${fqdn}/${fqdn}_fullchain.pem"
}

function renew_ca_and_certs {
  if [ ! -f $config_file ]; then
    echo "No CA configuration found."
    return
  fi
  source $config_file

  read -p "Reuse existing CA key? (yes/no): " reuse_key
  read -p "Enter new CA validity in years: " validity_years
  validity_days=$((validity_years * 365))

  if [ "$reuse_key" == "yes" ]; then
    openssl req -new -x509 -days $validity_days -key "${ca_path}/${ca_name}.key" -out "${ca_path}/${ca_name}.crt" || { echo "Error renewing CA certificate"; exit 1; }
  else
    read -p "Enter bit length (1024, 2048, 4096): " bit_len
    openssl genrsa -out "${ca_path}/${ca_name}.key" $bit_len || { echo "Error creating new CA key"; exit 1; }
    openssl req -new -x509 -days $validity_days -key "${ca_path}/${ca_name}.key" -out "${ca_path}/${ca_name}.crt" || { echo "Error creating new CA certificate"; exit 1; }
  fi

  echo "CA renewed. Now renewing all certificates..."

  for dir in "$cert_path"/*; do
    fqdn=$(basename "$dir")
    if [ -f "${dir}/${fqdn}.cnf" ] && [ -f "${dir}/${fqdn}.key" ]; then
      openssl req -new -key "${dir}/${fqdn}.key" -config "${dir}/${fqdn}.cnf" -out "${dir}/${fqdn}.csr" || continue
      openssl x509 -req -days $validity_days -in "${dir}/${fqdn}.csr" -CA "${ca_path}/${ca_name}.crt" -CAkey "${ca_path}/${ca_name}.key" -CAcreateserial -out "${dir}/${fqdn}.crt" -extensions v3_req -extfile "${dir}/${fqdn}.cnf" || continue
      cat "${dir}/${fqdn}.crt" "${ca_path}/${ca_name}.crt" > "${dir}/${fqdn}.fullchain.crt"

      password=$(openssl rand -base64 32)
      echo "$password" > "${dir}/p12_pkcs_password.key"
      chmod 600 "${dir}/p12_pkcs_password.key"

      openssl pkcs12 -export -out "${dir}/${fqdn}.p12" -inkey "${dir}/${fqdn}.key" -in "${dir}/${fqdn}.crt" -certfile "${ca_path}/${ca_name}.crt" -passout pass:"$password"
      openssl pkcs12 -export -out "${dir}/${fqdn}_fullchain.p12" -inkey "${dir}/${fqdn}.key" -in "${dir}/${fqdn}.fullchain.crt" -passout pass:"$password"

      cat "${dir}/${fqdn}.key" "${dir}/${fqdn}.crt" > "${dir}/${fqdn}.pem"
      cat "${dir}/${fqdn}.key" "${dir}/${fqdn}.crt" "${ca_path}/${ca_name}.crt" > "${dir}/${fqdn}_fullchain.pem"
    fi
  done
}

function renew_single_certificate {
  if [ ! -f $config_file ]; then
    echo "No CA configuration found."
    return
  fi
  source $config_file

  if [ -z "$ca_name" ]; then
    echo "CA name not found in config."
    return
  fi

  echo "Available certificates:"
  i=1
  declare -a cert_list
  for dir in "$cert_path"/*; do
    fqdn=$(basename "$dir")
    if [ -f "${dir}/${fqdn}.cnf" ] && [ -f "${dir}/${fqdn}.key" ]; then
      echo "$i) $fqdn"
      cert_list+=("$fqdn")
      ((i++))
    fi
  done

  if [ ${#cert_list[@]} -eq 0 ]; then
    echo "No valid certificates found."
    return
  fi

  read -p "Select certificate to renew (1-${#cert_list[@]}): " selection
  selected_fqdn="${cert_list[$((selection-1))]}"
  dir="${cert_path}/${selected_fqdn}"

  read -p "Enter new validity (years): " validity
  validity_days=$((validity * 365))

  openssl req -new -key "${dir}/${selected_fqdn}.key" -config "${dir}/${selected_fqdn}.cnf" -out "${dir}/${selected_fqdn}.csr" || return
  openssl x509 -req -days $validity_days -in "${dir}/${selected_fqdn}.csr" -CA "${ca_path}/${ca_name}.crt" -CAkey "${ca_path}/${ca_name}.key" -CAcreateserial -out "${dir}/${selected_fqdn}.crt" -extensions v3_req -extfile "${dir}/${selected_fqdn}.cnf" || return

  cat "${dir}/${selected_fqdn}.crt" "${ca_path}/${ca_name}.crt" > "${dir}/${selected_fqdn}.fullchain.crt"

  password=$(openssl rand -base64 32)
  echo "$password" > "${dir}/p12_pkcs_password.key"
  chmod 600 "${dir}/p12_pkcs_password.key"

  openssl pkcs12 -export -out "${dir}/${selected_fqdn}.p12" -inkey "${dir}/${selected_fqdn}.key" -in "${dir}/${selected_fqdn}.crt" -certfile "${ca_path}/${ca_name}.crt" -passout pass:"$password"
  openssl pkcs12 -export -out "${dir}/${selected_fqdn}_fullchain.p12" -inkey "${dir}/${selected_fqdn}.key" -in "${dir}/${selected_fqdn}.fullchain.crt" -passout pass:"$password"

  cat "${dir}/${selected_fqdn}.key" "${dir}/${selected_fqdn}.crt" > "${dir}/${selected_fqdn}.pem"
  cat "${dir}/${selected_fqdn}.key" "${dir}/${selected_fqdn}.crt" "${ca_path}/${ca_name}.crt" > "${dir}/${selected_fqdn}_fullchain.pem"

  echo "Certificate renewed: $selected_fqdn"
}

# Initial check and create directories
check_and_create_directories

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

echo "Choose an option:"
echo "1. Create CA"
echo "2. Create Certificate"
echo "3. Renew CA and Certificates"
echo "4. Renew single Certificate"

read -p "Option (1/2/3/4): " option

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
  3)
    echo "Renew CA and all Certificates selected."
    renew_ca_and_certs
    ;;
  4)
    echo "Renew single Certificate selected."
    renew_single_certificate
    ;;
  *)
    echo "Invalid option."
    ;;
esac
