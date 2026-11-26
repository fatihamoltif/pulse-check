#!/usr/bin/env bash
# samba-ad-dc.sh - Controleur de domaine Samba AD sur srv-ad01 (10.0.20.10), CH Saint-Pouls
#
# Domaine : ch-saintpouls.local (NetBIOS CHSP), DNS interne Samba, redirection vers gw-routeur.
# Demande 3 mots de passe complexes (8+ caracteres, majuscule, minuscule, chiffre) :
#   1. Administrator   2. svc-keycloak (compte de federation LDAP)   3. comptes fictifs du personnel
# Usage : en root (su -), bash samba-ad-dc.sh      Duree : ~5 min
# Comptes 100 % FICTIFS.

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "A lancer en root (su -)."; exit 1; }

REALM=CH-SAINTPOULS.LOCAL
DOMAIN=ch-saintpouls.local
NETBIOS=CHSP
IP=10.0.20.10
FWD=10.0.20.254
HOST=srv-ad01
BASE="DC=ch-saintpouls,DC=local"

# --- Verifications de depart ---
if ! ip -4 -o addr | grep -q " $IP/"; then
  echo "Cette VM n'a pas l'IP $IP. Corriger le DHCP sur gw-routeur d'abord."; exit 1
fi

complex() { # 8+ car., majuscule, minuscule, chiffre, pas d'apostrophe
  [ "${#1}" -ge 8 ] && [[ "$1" =~ [A-Z] ]] && [[ "$1" =~ [a-z] ]] \
    && [[ "$1" =~ [0-9] ]] && [[ "$1" != *"'"* ]]
}
ask() { # ask <variable> <libelle>
  local a b
  while true; do
    read -rsp "$2 : " a; echo
    read -rsp "Confirmer : " b; echo
    if [ "$a" != "$b" ]; then echo "Differents, recommence."; continue; fi
    if complex "$a"; then break; fi
    echo "Pas assez complexe (8+, majuscule, minuscule, chiffre, sans apostrophe)."
  done
  printf -v "$1" '%s' "$a"
}

echo "== 1/7 Mots de passe (a noter dans le gestionnaire du groupe) =="
ask ADMIN_PASS "Mot de passe Administrator"
ask SVC_PASS   "Mot de passe svc-keycloak"
ask USERS_PASS "Mot de passe des comptes fictifs du personnel"

echo "== 2/7 Nom de machine et /etc/hosts =="
hostnamectl set-hostname "$HOST"
# Empeche cloud-init de remettre 127.0.1.1 srv-ad01 au prochain demarrage
mkdir -p /etc/cloud/cloud.cfg.d
printf "manage_etc_hosts: false\nmanage_resolv_conf: false\n" \
  > /etc/cloud/cloud.cfg.d/99-samba-dc.cfg
sed -i "/[[:space:]]$HOST\b/d" /etc/hosts
echo "$IP $HOST.$DOMAIN $HOST" >> /etc/hosts

echo "== 3/7 Paquets =="
export DEBIAN_FRONTEND=noninteractive
echo "krb5-config krb5-config/default_realm string $REALM" | debconf-set-selections
apt-get update -q
apt-get install -y -q samba samba-ad-dc krb5-user winbind smbclient \
  dnsutils ldb-tools chrony

echo "== 4/7 Liberation du port 53 et resolution DNS locale =="
if systemctl is-active -q systemd-resolved 2>/dev/null; then
  systemctl disable --now systemd-resolved
fi
# Le client DHCP ne doit plus reecrire resolv.conf
if [ -f /etc/dhcp/dhclient.conf ]; then
  grep -q "supersede domain-name-servers" /etc/dhcp/dhclient.conf || \
    echo "supersede domain-name-servers 127.0.0.1;" >> /etc/dhcp/dhclient.conf
fi
rm -f /etc/resolv.conf
printf "search %s\nnameserver 127.0.0.1\n" "$DOMAIN" > /etc/resolv.conf

echo "== 5/7 Provisionnement du domaine =="
systemctl disable --now smbd nmbd winbind 2>/dev/null || true
systemctl mask smbd nmbd winbind 2>/dev/null || true
if [ -f /var/lib/samba/private/sam.ldb ]; then
  echo "Domaine deja provisionne, etape sautee."
else
  rm -f /etc/samba/smb.conf
  samba-tool domain provision \
    --use-rfc2307 \
    --realm="$REALM" \
    --domain="$NETBIOS" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --host-ip="$IP" \
    --adminpass="$ADMIN_PASS" \
    --option="dns forwarder = $FWD"
fi
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl unmask samba-ad-dc
systemctl enable --now samba-ad-dc
sleep 5

echo "== 6/7 OU, groupes et comptes fictifs =="
mkou() { samba-tool ou create "$1,$BASE" >/dev/null 2>&1 || true; }  # deja creee : ignore
mkou "OU=CHSP"
mkou "OU=Personnel,OU=CHSP"
mkou "OU=Comptes de service,OU=CHSP"
mkgrp() { samba-tool group show "$1" >/dev/null 2>&1 \
  || samba-tool group add "$1" --groupou="OU=CHSP"; }
mkgrp GRP-Infirmiers
mkgrp GRP-Medecins
mkgrp GRP-Secretariat
samba-tool ou list | grep CHSP || true
mkuser() { # mkuser <login> <prenom> <nom> <ou> <mdp> [groupe]
  if ! samba-tool user show "$1" >/dev/null 2>&1; then
    samba-tool user create "$1" "$5" --given-name="$2" --surname="$3" \
      --userou="$4" --mail-address="$1@$DOMAIN"
  fi
  [ -n "${6:-}" ] && samba-tool group addmembers "$6" "$1" >/dev/null 2>&1 || true
}
mkuser svc-keycloak "Service" "Keycloak" "OU=Comptes de service,OU=CHSP" "$SVC_PASS"
samba-tool user setexpiry svc-keycloak --noexpiry
mkuser i.dupont  "Isabelle" "DUPONT" "OU=Personnel,OU=CHSP" "$USERS_PASS" GRP-Infirmiers
mkuser m.leroy   "Marc"     "LEROY"  "OU=Personnel,OU=CHSP" "$USERS_PASS" GRP-Medecins
mkuser s.moreau  "Sarah"    "MOREAU" "OU=Personnel,OU=CHSP" "$USERS_PASS" GRP-Secretariat

echo "== 7/7 Verifications =="
samba-tool domain level show 2>/dev/null | grep -i "forest\|domain function" || true
host -t SRV "_ldap._tcp.$DOMAIN" 127.0.0.1 | tail -n 1 || true
host -t A "$HOST.$DOMAIN" 127.0.0.1 | tail -n 1 || true
host -t A deb.debian.org 127.0.0.1 >/dev/null && echo "Redirection DNS vers $FWD : OK"
printf '%s\n' "$ADMIN_PASS" | kinit "administrator@$REALM" >/dev/null 2>&1 \
  && echo "Kerberos (kinit administrator) : OK" || echo "Kerberos : ECHEC, verifier l'heure (chronyc tracking)"
ss -ltn | grep -qE ':636 ' && echo "LDAPS (636) : OK, pour Keycloak" || echo "LDAPS (636) : pas encore a l'ecoute"

cat <<EOF

OK. Domaine $DOMAIN (NetBIOS $NETBIOS) en service sur $IP.
  Admin      : Administrator
  Keycloak   : svc-keycloak  (DN : CN=Service Keycloak,OU=Comptes de service,OU=CHSP,$BASE)
               connexion : ldaps://$IP:636   base des comptes : OU=Personnel,OU=CHSP,$BASE
  Personnel  : i.dupont (infirmiere), m.leroy (medecin), s.moreau (secretariat)
EOF
