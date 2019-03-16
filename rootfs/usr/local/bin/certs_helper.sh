#!/bin/bash

ACME_PATH=/etc/letsencrypt/acme
ACME_FILE="$ACME_PATH"/acme.json
ACME_DUMP=/var/mail/ssl/acme_dump.log
SELFSIGNED_PATH=/var/mail/ssl/selfsigned
CERT_TEMP_PATH=/tmp/ssl
LETS_ENCRYPT_LIVE_PATH=/etc/letsencrypt/live/"$FQDN"
LIVE_CERT_PATH=/ssl
RENEWED_CERTIFICATE=false

_normalize_certs() {
  SSL_DIR="$1"
  FULLCHAIN="$SSL_DIR"/fullchain.pem
  CAFILE="$SSL_DIR"/chain.pem
  CERTFILE="$SSL_DIR"/cert.pem
  KEYFILE="$SSL_DIR"/privkey.pem

  # When using https://github.com/jwilder/nginx-proxy there is only key.pem
  if [ -e "$SSL_DIR"/key.pem ]; then
    mv -f "$SSL_DIR"/key.pem "$KEYFILE"
  fi

  if [ ! -e "$KEYFILE" ]; then
    echo "[ERROR] No keyfile found in $SSL_DIR !"
    exit 1
  fi

  if [ "$RENEWED_CERTIFICATE" = true ] || [ ! -e "$CAFILE" ] || [ ! -e "$CERTFILE" ]; then
    # if [ ! -e "$FULLCHAIN" ]; then
    #   echo "[ERROR] No fullchain found in $SSL_DIR !"
    #   exit 1
    # fi

    if [ -e "$FULLCHAIN" ]; then
      # Extract cert.pem and chain.pem from fullchain.pem
      # Used for containous/traefik and jwilder/nginx-proxy
      awk -v path="$SSL_DIR" 'BEGIN {c=0;} /BEGIN CERT/{c++} { print > path"/cert" c ".pem"}' < "$FULLCHAIN"
      mv "$SSL_DIR"/cert1.pem "$CERTFILE"
      mv "$SSL_DIR"/cert2.pem "$CAFILE"
    fi
  fi

  if [ ! -e "$FULLCHAIN" ]; then
    cp "$CERTFILE" "$FULLCHAIN"
  fi
}

if [ "$1" = "watch" ]; then
  echo "[INFO] Checking for watchable SSL certificates"
  if [ -f "$ACME_FILE" ]; then
    exec watcher.py "$ACME_PATH"
  elif [ -d "$LETS_ENCRYPT_LIVE_PATH" ]; then
    exec watcher.py "$LETS_ENCRYPT_LIVE_PATH"
  else
    echo "[INFO] No watchable SSL certificate mounts - disabling SSL watcher"
  fi

elif [ "$1" = "update_certs" ]; then
  mkdir -p "$LIVE_CERT_PATH"
  rm -rf "$LIVE_CERT_PATH/*"

  NORMALIZED_CERT_PATH="$CERT_TEMP_PATH"/normalized

  if [ -f "$ACME_FILE" ]; then
    echo "[INFO] Search for SSL certificates generated by Traefik"

    if [ ! "$2" = "-n" ]; then
      while [ ! -s "$ACME_FILE" ]; do
        sleep 5
        echo "[INFO] ..."
      done

      # Wait for acme.json full filling
      sleep 10
    fi

    mkdir -p "$CERT_TEMP_PATH"
    rm -rf "$CERT_TEMP_PATH/*"

    if jq -e -r '.PrivateKey' "$ACME_FILE" >/dev/null ; then
      echo "[INFO] acme.json found with ACME v1 format, dumping into pem files" | tee -a "$ACME_DUMP"
      dumpcerts.acme.v1.sh "$ACME_FILE" "$CERT_TEMP_PATH" >> "$ACME_DUMP" 2>&1
    elif jq -e -r '.Account.PrivateKey' "$ACME_FILE" >/dev/null ; then
        echo "[INFO] acme.json found with ACME v2 format, dumping into pem files" | tee -a "$ACME_DUMP"
        dumpcerts.acme.v2.sh "$ACME_FILE" "$CERT_TEMP_PATH" >> "$ACME_DUMP" 2>&1
        if [ -e "$CERT_TEMP_PATH"/certs/"*.${DOMAIN}.crt" ] && [ -e "$CERT_TEMP_PATH"/private/"*.${DOMAIN}.key" ]; then
          echo "[INFO] Let's encrypt wildcard certificate found" | tee -a "$ACME_DUMP"
          mv -f "$CERT_TEMP_PATH"/certs/"*.${DOMAIN}.crt" "$CERT_TEMP_PATH"/certs/"$FQDN".crt
          mv -f "$CERT_TEMP_PATH"/private/"*.${DOMAIN}.key" "$CERT_TEMP_PATH"/private/"$FQDN".key
        fi
    else
      echo "[ERROR] acme.json found but with an unknown format" >> "$ACME_DUMP"
    fi

    if [ -e "$CERT_TEMP_PATH"/certs/"$FQDN".crt ] && [ -e "$CERT_TEMP_PATH"/private/"$FQDN".key ]; then
      DOMAIN_NAME="$FQDN"
    elif [ -e "$CERT_TEMP_PATH"/certs/"$DOMAIN".crt ] && [ -e "$CERT_TEMP_PATH"/private/"$DOMAIN".key ]; then
      DOMAIN_NAME="$DOMAIN"
    else
      echo "[ERROR] The certificate for ${FQDN} or the private key was not found !"
      echo "[INFO] Don't forget to add a new traefik frontend rule to generate a certificate for ${FQDN} subdomain"
      echo "[INFO] Look /mnt/docker/traefik/acme/dump.log and 'docker logs traefik' for more information"
      exit 1
    fi

    mv -f "$CERT_TEMP_PATH"/certs/"$DOMAIN_NAME".crt "$NORMALIZED_CERT_PATH"/fullchain.pem
    mv -f "$CERT_TEMP_PATH"/private/"$DOMAIN_NAME".key "$NORMALIZED_CERT_PATH"/privkey.pem
    rm -rf "$ACME_DUMP"
    RENEWED_CERTIFICATE=true
  else
    echo "[INFO] Traefik SSL certificates not used"

    if [ -d "$LETS_ENCRYPT_LIVE_PATH" ]; then
      echo "[INFO] Let's encrypt live directory found"
      echo "[INFO] Using $LETS_ENCRYPT_LIVE_PATH folder"

      cp -RT "$LETS_ENCRYPT_LIVE_PATH/." "$NORMALIZED_CERT_PATH"

    else
      echo "[INFO] No Let's encrypt live directory found"
      echo "[INFO] Using "$SELFSIGNED_PATH"/ folder"

      CERTFILE="$SELFSIGNED_PATH"/cert.pem
      KEYFILE="$SELFSIGNED_PATH"/privkey.pem

      if [ ! -e "$CERTFILE" ] || [ ! -e "$KEYFILE" ]; then
        echo "[INFO] No SSL certificates found, generating a new selfsigned certificate"
        mkdir -p /var/mail/ssl/selfsigned/
        openssl req -new -newkey rsa:4096 -days 3658 -sha256 -nodes -x509 \
          -subj "/C=FR/ST=France/L=Paris/O=Mailserver certificate/OU=Mail/CN=*.${DOMAIN}/emailAddress=postmaster@${DOMAIN}" \
          -keyout "$KEYFILE" \
          -out "$CERTFILE"
      fi

      cp -RT "$SELFSIGNED_PATH/." "$NORMALIZED_CERT_PATH"
    fi
  fi

  _normalize_certs "$NORMALIZED_CERT_PATH"
  [ $? -ne 0 ] && exit 1

  # Compare Old and New key
  if cmp --silent "$NORMALIZED_CERT_PATH"/privkey "$LIVE_CERT_PATH"/privkey; then
    echo "[INFO] Live Certificates match"
    rm -rf "$CERT_TEMP_PATH"
    exit 1
  fi

  cp -RT "$NORMALIZED_CERT_PATH/." "$LIVE_CERT_PATH"

  # Comment CAfile directives if Let's Encrypt CA is not used
  if [ -f "$LIVE_CERT_PATH"/chain.pem ]; then
    sed -i '/^#\(smtp_tls_CAfile\|smtpd_tls_CAfile\)/s/^#//' /etc/postfix/main.cf
  else
    sed -i '/^\(smtp_tls_CAfile\|smtpd_tls_CAfile\)/s/^/#/' /etc/postfix/main.cf
  fi

elif [ "$1" = "reload" ]; then
  echo "[INFO] Updating SSL certificates and reloading"
  if "$0" update_certs -n; then
    s6-svc -r /services/postfix
    s6-svc -r /services/dovecot
    echo "[INFO] Reloaded Postfix + Dovecot"
  fi

else
  echo "[ERROR] Unrecognized command '$1'"
  exit 1
fi
