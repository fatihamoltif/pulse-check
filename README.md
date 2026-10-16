# pulse-check

                CHECK THE PUL(L)SE,DOC!!
-----------------------------------------------------------
Simulation d'une cyberattaque par vol d'identifiants en milieu hospitalier, et
evaluation de la reponse de defense dans un jumeau numerique.

Projet 4A STI - INSA Centre Val de Loire.

## Membres

-Fatiha Moltif
-Imen Mezrigui
-Ali Jamai
-Youssef Rammeh

## Idee generale

Un infostealer compromet des postes de soins et des appareils personnels (BYOD),
vole des identifiants (cookies, mots de passe, jetons SSO), puis sert a pivoter par
l'identite (Active Directory / SSO) jusqu'au dossier patient informatise (DPI).

L'objectif n'est pas d'attaquer, mais de **detecter, contenir et remedier** :
on rejoue l'attaque dans un environnement isole pour mesurer la capacite de defense
(detection, temps de reaction, couverture) et sensibiliser aux enjeux de
confidentialite des donnees de sante.

## Cadre

- **Scenario** : P13-H - infostealer via postes soignants / BYOD, acces au DPI.
- **Chaine d'outils** : renseignement prepare a la main (ANSSI/CERT-FR, MITRE ATT&CK)
  -> OpenAEV (injects + timeline) -> Ludus (jumeau numerique) -> ELK (detection).
- **Format** : exercice de 3h (attaque, remediation, debrief).
- **Simulation uniquement** : jumeau virtuel, services factices (dont le DPI),
  donnees fictives. Aucun vrai malware, aucun logiciel de sante ni donnee patient reelle.

## Documentation ( to be updated)

- [ARCHITECTURE.md](ARCHITECTURE.md) - architecture (vue logique + reseau), schema et timeline des injects.
