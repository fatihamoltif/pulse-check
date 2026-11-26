#!/usr/bin/env bash
# install-openemr.sh - DPI OpenEMR sur srv-dpi01 (10.0.40.10), CH Saint-Pouls (pulse-check)
#
# OpenEMR 7.0.3 + MariaDB 11.4 en Docker.
# Pourquoi Docker : OpenEMR 7.0.3 est supporte avec MariaDB 10.5-11.4, Debian 13 fournit 11.8.
# L'image officielle sert deja OpenEMR en HTTPS (certificat auto-signe) sur le port 443.
#
# Usage (root, sur srv-dpi01) : bash install-openemr.sh
# Duree : 5 a 15 minutes (telechargement des images + premiere initialisation).
# Donnees : patients 100 % FICTIFS.

set -euo pipefail

DIR=/opt/openemr
DB=openemr

[ "$(id -u)" -eq 0 ] || { echo "A lancer en root."; exit 1; }

ask() { # ask <variable> <libelle>
  local a b
  while true; do
    read -rsp "$2 : " a; echo
    read -rsp "Confirmer : " b; echo
    case "$a" in *"'"*) echo "Pas d'apostrophe ' dans le mot de passe, recommence."; continue;; esac
    [ -n "$a" ] && [ "$a" = "$b" ] && break
    echo "Vide ou different, recommence."
  done
  printf -v "$1" '%s' "$a"
}

echo "== 1/6 Mots de passe (a noter dans le gestionnaire du groupe, pas dans le depot) =="
ask DB_ROOT_PASS "Mot de passe root MariaDB"
ask DB_USER_PASS "Mot de passe du compte MariaDB 'openemr'"
ask OE_ADMIN_PASS "Mot de passe du compte OpenEMR 'admin'"

echo "== 2/6 Liberation des ports 80/443 (pile LAMP du template) =="
for s in apache2 mariadb mysql; do
  if systemctl list-unit-files "$s.service" >/dev/null 2>&1; then
    systemctl disable --now "$s" 2>/dev/null || true
  fi
done

echo "== 3/6 Installation de Docker =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q docker.io docker-compose curl
systemctl enable --now docker
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi

echo "== 4/6 Ecriture de $DIR =="
mkdir -p "$DIR"
umask 077
cat > "$DIR/.env" <<EOF
DB_ROOT_PASS='$DB_ROOT_PASS'
DB_USER_PASS='$DB_USER_PASS'
OE_ADMIN_PASS='$OE_ADMIN_PASS'
EOF
cat > "$DIR/docker-compose.yml" <<'EOF'
services:
  mysql:
    image: mariadb:11.4
    restart: always
    command: ["mariadbd", "--character-set-server=utf8mb4"]
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
    volumes:
      - databasevolume:/var/lib/mysql
  openemr:
    image: openemr/openemr:7.0.3
    restart: always
    depends_on: [mysql]
    ports:
      - "80:80"
      - "443:443"
    environment:
      MYSQL_HOST: mysql
      MYSQL_ROOT_PASS: ${DB_ROOT_PASS}
      MYSQL_USER: openemr
      MYSQL_PASS: ${DB_USER_PASS}
      OE_USER: admin
      OE_PASS: ${OE_ADMIN_PASS}
    volumes:
      - logvolume:/var/log
      - sitevolume:/var/www/localhost/htdocs/openemr/sites
volumes:
  databasevolume: {}
  logvolume: {}
  sitevolume: {}
EOF
umask 022

echo "== 5/6 Demarrage (premiere initialisation : plusieurs minutes) =="
cd "$DIR"
$DC up -d
printf "Attente de la page de connexion"
for i in $(seq 1 90); do   # 90 x 10 s = 15 min max
  code=$(curl -ks -o /dev/null -w '%{http_code}' https://localhost/interface/login/login.php || true)
  [ "$code" = "200" ] && break
  printf "."; sleep 10
done
echo
[ "$code" = "200" ] || { echo "OpenEMR ne repond pas. Logs : cd $DIR && $DC logs --tail 50 openemr"; exit 1; }

echo "== 6/6 Patients fictifs =="
SQL() { $DC exec -T mysql mariadb -uroot -p"$DB_ROOT_PASS" "$DB" "$@"; }
if [ "$(SQL -N -e "SELECT COUNT(*) FROM patient_data WHERE pubpid='CHSP-0001'")" = "0" ]; then
  SQL <<'EOF'
SET SESSION sql_mode = '';
SET @p := (SELECT IFNULL(MAX(pid), 0) FROM patient_data);
INSERT INTO patient_data (uuid, pid, pubpid, title, fname, lname, DOB, sex, street, postal_code, city, country_code, phone_home, date, regdate) VALUES
 (UNHEX(REPLACE(UUID(),'-','')), @p+1, 'CHSP-0001', 'Mme', 'Marie',  'DURAND',  '1958-03-12', 'Female', '3 rue des Tilleuls',  '45000', 'Saint-Pouls', 'FR', '0600000001', NOW(), NOW()),
 (UNHEX(REPLACE(UUID(),'-','')), @p+2, 'CHSP-0002', 'M.',  'Jean',   'MARTIN',  '1972-07-04', 'Male',   '18 avenue du Parc',   '45000', 'Saint-Pouls', 'FR', '0600000002', NOW(), NOW()),
 (UNHEX(REPLACE(UUID(),'-','')), @p+3, 'CHSP-0003', 'Mme', 'Lucie',  'BERNARD', '1990-11-23', 'Female', '7 place de la Gare',  '45000', 'Saint-Pouls', 'FR', '0600000003', NOW(), NOW()),
 (UNHEX(REPLACE(UUID(),'-','')), @p+4, 'CHSP-0004', 'M.',  'Ahmed',  'BENALI',  '1965-01-30', 'Male',   '22 rue Victor Hugo',  '45000', 'Saint-Pouls', 'FR', '0600000004', NOW(), NOW()),
 (UNHEX(REPLACE(UUID(),'-','')), @p+5, 'CHSP-0005', 'Mme', 'Sophie', 'PETIT',   '2001-05-17', 'Female', '5 impasse des Roses', '45000', 'Saint-Pouls', 'FR', '0600000005', NOW(), NOW()),
 (UNHEX(REPLACE(UUID(),'-','')), @p+6, 'CHSP-0006', 'M.',  'Paul',   'ROUX',    '1949-09-08', 'Male',   '11 chemin du Moulin', '45000', 'Saint-Pouls', 'FR', '0600000006', NOW(), NOW());
EOF
  echo "6 patients fictifs crees (CHSP-0001 a CHSP-0006)."
else
  echo "Patients fictifs deja presents, rien a faire."
fi

IP=$(hostname -I | awk '{print $1}')
cat <<EOF

OK. DPI disponible : https://$IP/   (certificat auto-signe : accepter l'exception dans Firefox)
Connexion : admin / <mot de passe OpenEMR saisi plus haut>
Patients : menu Patient > Rechercher, ou recherche "DURAND".
Gestion : cd $DIR && $DC ps | $DC logs -f openemr | $DC restart
EOF
