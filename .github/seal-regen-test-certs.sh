#!/usr/bin/env bash
# Seal Security: regenerate the TLS test fixtures under test/org/apache/tomcat/util/net
# when any of them has expired. user1.jks (the mTLS client certificate) expired on
# 2025-08-15, so every client-certificate suite (TestClientCert, TestClientCertTls13,
# TestSsl, ...) would fail with "certificate_unknown". These files never enter the jar.
# They are regenerated in the CI checkout, not in the source tree, because the .jks
# stores are binary and are signed by the test CA whose private key is not in the repo.
# When every fixture is still valid (e.g. a later patch ships refreshed upstream
# fixtures) nothing is touched. Shapes reproduce the originals (CA "Apache Tomcat Test
# CA", RSA + EC "localhost" leaves with SAN DNS:localhost,IP:127.0.0.1, RSA "user1"
# client leaf; aliases ca/tomcat/user1; password changeit, localhost-rsa-copy1.jks
# keyed on tomcatpass), valid 20 years.
set -eo pipefail
CERTDIR=test/org/apache/tomcat/util/net
expired=""
for pem in ca-cert.pem localhost-rsa-cert.pem localhost-ec-cert.pem; do
  if ! openssl x509 -checkend 86400 -noout -in "$CERTDIR/$pem" > /dev/null; then
    expired="$expired $pem"
  fi
done
for ks in user1.jks:user1 localhost-rsa.jks:tomcat localhost-ec.jks:tomcat; do
  f="${ks%%:*}"; a="${ks##*:}"
  if ! keytool -exportcert -rfc -alias "$a" -keystore "$CERTDIR/$f" -storepass changeit 2> /dev/null \
      | openssl x509 -checkend 86400 -noout > /dev/null; then
    expired="$expired $f"
  fi
done
if [ -z "$expired" ]; then
  echo "TLS test fixtures are all valid; leaving them untouched"
  exit 0
fi
echo "Expired TLS test fixtures:$expired -- regenerating the whole set"
CERTWORK=$(mktemp -d)

cat > "$CERTWORK/ca.cnf" <<'CACNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
C  = US
ST = MA
L  = Wakefield
O  = The Apache Software Foundation
OU = Apache Tomcat PMC
CN = Apache Tomcat Test CA
[v3_ca]
basicConstraints = CA:TRUE
subjectKeyIdentifier = hash
CACNF

cat > "$CERTWORK/localhost.ext" <<'LHEXT'
basicConstraints = CA:FALSE
nsComment = "OpenSSL Generated Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
subjectAltName = DNS:localhost,IP:127.0.0.1
LHEXT

cat > "$CERTWORK/user1.ext" <<'U1EXT'
basicConstraints = CA:FALSE
nsComment = "OpenSSL Generated Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
keyUsage = digitalSignature,nonRepudiation,keyEncipherment
U1EXT

LEAF_DN="/C=US/ST=DE/L=Wilmington/O=The Apache Software Foundation/OU=Apache Tomcat PMC/CN="

openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 7300 \
    -config "$CERTWORK/ca.cnf" -keyout "$CERTWORK/ca-key.pem" -out "$CERTWORK/ca-cert.pem"

openssl genrsa -out "$CERTWORK/rsa-pkcs1.pem" 2048
openssl pkcs8 -topk8 -nocrypt -in "$CERTWORK/rsa-pkcs1.pem" -out "$CERTWORK/localhost-rsa-key.pem"
openssl req -new -key "$CERTWORK/localhost-rsa-key.pem" -subj "${LEAF_DN}localhost" -out "$CERTWORK/rsa.csr"
openssl x509 -req -in "$CERTWORK/rsa.csr" -CA "$CERTWORK/ca-cert.pem" -CAkey "$CERTWORK/ca-key.pem" \
    -CAcreateserial -days 7300 -sha256 -extfile "$CERTWORK/localhost.ext" -out "$CERTWORK/localhost-rsa.crt"

openssl ecparam -name prime256v1 -genkey -noout -out "$CERTWORK/ec-sec1.pem"
{ openssl ecparam -name prime256v1; cat "$CERTWORK/ec-sec1.pem"; } > "$CERTWORK/localhost-ec-key.pem"
openssl req -new -key "$CERTWORK/localhost-ec-key.pem" -subj "${LEAF_DN}localhost" -out "$CERTWORK/ec.csr"
openssl x509 -req -in "$CERTWORK/ec.csr" -CA "$CERTWORK/ca-cert.pem" -CAkey "$CERTWORK/ca-key.pem" \
    -CAcreateserial -days 7300 -sha256 -extfile "$CERTWORK/localhost.ext" -out "$CERTWORK/localhost-ec.crt"

openssl genrsa -out "$CERTWORK/user1-pkcs1.pem" 2048
openssl pkcs8 -topk8 -nocrypt -in "$CERTWORK/user1-pkcs1.pem" -out "$CERTWORK/user1-key.pem"
openssl req -new -key "$CERTWORK/user1-key.pem" -subj "${LEAF_DN}user1" -out "$CERTWORK/user1.csr"
openssl x509 -req -in "$CERTWORK/user1.csr" -CA "$CERTWORK/ca-cert.pem" -CAkey "$CERTWORK/ca-key.pem" \
    -CAcreateserial -days 7300 -sha256 -extfile "$CERTWORK/user1.ext" -out "$CERTWORK/user1.crt"

mk_jks() {
    local keyf="$1" certf="$2" chainf="$3" jks_alias="$4" out="$5" keypass="$6"
    local p12="$CERTWORK/${jks_alias}.$(basename "$out").p12"
    if [ -n "$chainf" ]; then
        openssl pkcs12 -export -name "$jks_alias" -inkey "$keyf" -in "$certf" -certfile "$chainf" \
            -out "$p12" -passout pass:changeit
    else
        openssl pkcs12 -export -name "$jks_alias" -inkey "$keyf" -in "$certf" \
            -out "$p12" -passout pass:changeit
    fi
    rm -f "$out"
    keytool -importkeystore -noprompt \
        -srckeystore "$p12" -srcstoretype PKCS12 -srcstorepass changeit -srcalias "$jks_alias" \
        -destkeystore "$out" -deststoretype JKS -deststorepass changeit \
        -destalias "$jks_alias" -destkeypass "$keypass"
}

rm -f "$CERTDIR/ca.jks"
keytool -importcert -noprompt -alias ca -file "$CERTWORK/ca-cert.pem" \
    -keystore "$CERTDIR/ca.jks" -storetype JKS -storepass changeit

mk_jks "$CERTWORK/localhost-rsa-key.pem" "$CERTWORK/localhost-rsa.crt" "$CERTWORK/ca-cert.pem" \
    tomcat "$CERTDIR/localhost-rsa.jks" changeit
mk_jks "$CERTWORK/localhost-rsa-key.pem" "$CERTWORK/localhost-rsa.crt" "" \
    tomcat "$CERTDIR/localhost-rsa-copy1.jks" tomcatpass
mk_jks "$CERTWORK/localhost-ec-key.pem" "$CERTWORK/localhost-ec.crt" "" \
    tomcat "$CERTDIR/localhost-ec.jks" changeit
mk_jks "$CERTWORK/user1-key.pem" "$CERTWORK/user1.crt" "$CERTWORK/ca-cert.pem" \
    user1 "$CERTDIR/user1.jks" changeit

cp "$CERTWORK/ca-cert.pem"           "$CERTDIR/ca-cert.pem"
cp "$CERTWORK/localhost-rsa-key.pem" "$CERTDIR/localhost-rsa-key.pem"
cp "$CERTWORK/localhost-ec-key.pem"  "$CERTDIR/localhost-ec-key.pem"
openssl x509 -in "$CERTWORK/localhost-rsa.crt" -text > "$CERTDIR/localhost-rsa-cert.pem"
openssl x509 -in "$CERTWORK/localhost-ec.crt"  -text > "$CERTDIR/localhost-ec-cert.pem"
chmod 644 "$CERTDIR"/*.jks "$CERTDIR"/*.pem

openssl verify -CAfile "$CERTDIR/ca-cert.pem" "$CERTDIR/localhost-rsa-cert.pem"
openssl verify -CAfile "$CERTDIR/ca-cert.pem" "$CERTDIR/localhost-ec-cert.pem"
keytool -list -keystore "$CERTDIR/localhost-rsa.jks"       -storepass changeit -alias tomcat
keytool -list -keystore "$CERTDIR/localhost-rsa-copy1.jks" -storepass changeit -alias tomcat
keytool -list -keystore "$CERTDIR/localhost-ec.jks"        -storepass changeit -alias tomcat
keytool -list -keystore "$CERTDIR/user1.jks"               -storepass changeit -alias user1
keytool -list -keystore "$CERTDIR/ca.jks"                  -storepass changeit -alias ca
rm -rf "$CERTWORK"
