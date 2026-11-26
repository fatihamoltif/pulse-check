#!/usr/bin/env bash
# setup-elk.sh - Elasticsearch + Kibana (8.x) sur srv-elk01 (10.0.0.209), CH Saint-Pouls (pulse-check)
#
# Usage : en root (su -), bash setup-elk.sh      Duree : ~10 min
# Demande 2 mots de passe : 'elastic' (super-admin) et 'kibana_system' (compte technique de Kibana).
# Resultat : Elasticsearch https://10.0.0.209:9200 , Kibana http://10.0.0.209:5601

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "A lancer en root (su -)."; exit 1; }

ask() { # ask <variable> <libelle>
  local a b
  while true; do
    read -rsp "$2 (8 caracteres min.) : " a; echo
    read -rsp "Confirmer : " b; echo
    if [ "${#a}" -ge 8 ] && [ "$a" = "$b" ]; then break; fi
    echo "Trop court ou different, recommence."
  done
  printf -v "$1" '%s' "$a"
}

echo "== 1/7 Mots de passe (a noter dans le gestionnaire du groupe) =="
ask ELASTIC_PASS "Mot de passe du compte 'elastic'"
ask KIBANA_PASS  "Mot de passe du compte 'kibana_system'"

echo "== 2/7 Paquets de base et depot Elastic =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl gpg apt-transport-https ca-certificates python3 openssl
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --dearmor --yes -o /usr/share/keyrings/elasticsearch-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list
apt-get update -q

echo "== 3/7 Reglages systeme =="
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-elasticsearch.conf
sysctl -q -p /etc/sysctl.d/99-elasticsearch.conf
# Memoire Java : moitie de la RAM, entre 1 et 2 Go (Kibana a aussi besoin de place)
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
HEAP_MB=$(( RAM_MB / 2 )); [ "$HEAP_MB" -gt 2048 ] && HEAP_MB=2048; [ "$HEAP_MB" -lt 1024 ] && HEAP_MB=1024
echo "RAM : ${RAM_MB} Mo -> memoire Elasticsearch : ${HEAP_MB} Mo"
[ "$RAM_MB" -lt 3500 ] && echo "ATTENTION : moins de 4 Go de RAM, Kibana risque d'etre lent."

echo "== 4/7 Elasticsearch (securite et TLS configures automatiquement) =="
apt-get install -y -q elasticsearch
mkdir -p /etc/elasticsearch/jvm.options.d
printf -- "-Xms%sm\n-Xmx%sm\n" "$HEAP_MB" "$HEAP_MB" > /etc/elasticsearch/jvm.options.d/heap.options
YML=/etc/elasticsearch/elasticsearch.yml
grep -q '^cluster.name:' "$YML" || echo "cluster.name: chsp-soc" >> "$YML"
grep -q '^http.host:' "$YML" || echo "http.host: 0.0.0.0" >> "$YML"
systemctl daemon-reload
systemctl enable --now elasticsearch

printf "Attente d'Elasticsearch"
for i in $(seq 1 60); do
  code=$(curl -ks -o /dev/null -w '%{http_code}' https://localhost:9200 || true)
  [ "$code" = "401" ] || [ "$code" = "200" ] && break
  printf "."; sleep 5
done; echo
[ "$code" = "401" ] || [ "$code" = "200" ] || { echo "Elasticsearch ne repond pas : journalctl -u elasticsearch -n 50"; exit 1; }

echo "== 5/7 Mots de passe des comptes =="
TMP_PASS=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -a -s -b)
json() { python3 -c 'import json,sys; print(json.dumps({"password": sys.argv[1]}))' "$1"; }
setpw() { # setpw <compte> <mdp> <mdp_admin_actuel>
  curl -ksf -u "elastic:$3" -X POST "https://localhost:9200/_security/user/$1/_password" \
    -H 'Content-Type: application/json' -d "$(json "$2")" >/dev/null
}
setpw elastic "$ELASTIC_PASS" "$TMP_PASS"
setpw kibana_system "$KIBANA_PASS" "$ELASTIC_PASS"
curl -ksf -u "elastic:$ELASTIC_PASS" https://localhost:9200 >/dev/null && echo "Compte elastic OK."

echo "== 6/7 Kibana =="
apt-get install -y -q kibana
mkdir -p /etc/kibana/certs
cp /etc/elasticsearch/certs/http_ca.crt /etc/kibana/certs/http_ca.crt
chown -R root:kibana /etc/kibana/certs; chmod 640 /etc/kibana/certs/http_ca.crt
KYML=/etc/kibana/kibana.yml
[ -f "$KYML.orig" ] || cp "$KYML" "$KYML.orig"
cat > "$KYML" <<EOF
server.host: "0.0.0.0"
server.port: 5601
server.publicBaseUrl: "http://10.0.0.209:5601"
elasticsearch.hosts: ["https://localhost:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.ssl.certificateAuthorities: ["/etc/kibana/certs/http_ca.crt"]
xpack.encryptedSavedObjects.encryptionKey: "$(openssl rand -hex 32)"
xpack.security.encryptionKey: "$(openssl rand -hex 32)"
xpack.reporting.encryptionKey: "$(openssl rand -hex 32)"
logging.appenders.file.type: file
logging.appenders.file.fileName: /var/log/kibana/kibana.log
logging.appenders.file.layout.type: json
logging.root.appenders: [default, file]
EOF
chown root:kibana "$KYML"; chmod 640 "$KYML"
# Le mot de passe de kibana_system va dans le keystore, pas en clair dans kibana.yml
[ -f /etc/kibana/kibana.keystore ] || /usr/share/kibana/bin/kibana-keystore create
printf '%s' "$KIBANA_PASS" | /usr/share/kibana/bin/kibana-keystore add elasticsearch.password --stdin --force
chown root:kibana /etc/kibana/kibana.keystore; chmod 660 /etc/kibana/kibana.keystore
systemctl daemon-reload
systemctl enable --now kibana

echo "== 7/7 Attente de Kibana (1 a 3 min) =="
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5601/api/status || true)
  [ "$code" = "200" ] && break
  printf "."; sleep 5
done; echo
if [ "$code" = "200" ]; then
  cat <<EOF

OK.
  Kibana        : http://10.0.0.209:5601   (compte : elastic / <mot de passe saisi>)
  Elasticsearch : https://10.0.0.209:9200  (certificat auto-signe)
  Certificat CA (pour les futurs agents) : /etc/elasticsearch/certs/http_ca.crt
EOF
else
  echo "Kibana ne repond pas encore. Verifier : systemctl status kibana ; tail -n 50 /var/log/kibana/kibana.log"
fi
