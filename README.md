# README – Supervision du conteneur `pve-scripts-local`

## 1. Objectif

Ce conteneur LXC `pve-scripts-local` héberge l’application **PVE Scripts Local** (ProxmoxVE-Local), qui permet de gérer les scripts d’aide Proxmox en local, sans dépendre directement du site web.

Ce README décrit un script Bash qui :

- Vérifie l’état général du conteneur (OS, uptime, charge, mémoire, disques).
- Vérifie l’état de l’application **PVE Scripts Local** :
  - service systemd (`pvescriptslocal`) ;
  - accessibilité HTTP sur `http://127.0.0.1:3000`.
- Inventorie tous les scripts locaux sous ` /opt/ProxmoxVE-Local/scripts`.
- Détecte les **changements** dans ces scripts :
  - fichiers **nouveaux** (téléchargés) ;
  - fichiers **supprimés** ;
  - fichiers **modifiés** (taille ou date de modification).
- Envoie un **résumé** dans un canal **Discord** + un **log détaillé en pièce jointe**, en respectant :
  - la limite stricte de **2000 caractères** ;
  - un JSON propre via `jq -Rs` ;
  - l’envoi de fichier via `curl -F`.

Le script est prévu pour tourner **tous les jours à 06h00** via `cron`.

---

## 2. Principe de fonctionnement

1. **Collecte d’informations système**
   - OS, hostname, IP, uptime humain + date de démarrage, charge moyenne, mémoire utilisée.
   - Espace disque sur `/` et sur le répertoire applicatif `/opt/ProxmoxVE-Local`.

2. **Vérification de PVE Scripts Local**
   - Lecture de la version de l’application (fichier `VERSION` si présent).
   - Version de Node.js (`node -v`).
   - Statut du service `pvescriptslocal` via `systemctl`.
   - Test HTTP sur `http://127.0.0.1:3000` via `curl` (code HTTP ou absence de réponse).

3. **Inventaire des scripts locaux**
   - Répertoire principal : `LOCAL_SCRIPTS_DIR=/opt/ProxmoxVE-Local/scripts`.
   - Comptage du nombre de fichiers scripts.
   - Calcul de la taille totale.

4. **Baseline et détection de changements**
   - Le script maintient un fichier de référence :
     - `BASELINE=/var/lib/pve-scripts-local/scripts_baseline.txt`
   - Format : `chemin_relatif|taille|mtime_epoch`, trié.
   - Première exécution :
     - Tous les fichiers sont considérés comme l’état initial.
   - Exécutions suivantes :
     - Détection :
       - des **nouveaux fichiers** (présents maintenant, absents avant) ;
       - des **fichiers supprimés** (présents avant, absents maintenant) ;
       - des **fichiers modifiés** (taille ou date modifiée).
     - Résumé des changements sous forme :
       - `X nouveau(x), Y supprimé(s), Z modifié(s).`

5. **Log détaillé et envoi vers Discord**
   - Un log complet est généré à chaque exécution dans :
     - `/var/log/pve-scripts-local/pve-scripts-local_status_YYYY-MM-DDTHH-MM-SS+ZZZZ.log`
   - Le message Discord contient un **résumé synthétique** :
     - état du conteneur ;
     - état de l’application PVE Scripts Local ;
     - stats sur les scripts ;
     - résumé des changements.
   - Le message respecte la limite de **2000 caractères** (tronquage propre si nécessaire).
   - Le log complet est envoyé comme **pièce jointe** avec `curl -F`.

---

## 3. Prérequis

- Conteneur LXC `pve-scripts-local` sous **Debian 13**.
- Application **PVE Scripts Local** installée dans :
  - `/opt/ProxmoxVE-Local`
- Accès root (ou équivalent) dans le conteneur.
- Outils nécessaires :
  - `curl`
  - `jq` (installé automatiquement si absent).
- Un **webhook Discord** valide (URL à renseigner dans le script).

---

## 4. Installation du script

### 4.1. Création du répertoire des scripts

Dans le conteneur `pve-scripts-local` :

```bash
mkdir -p /home/scripts
```

### 4.2. Création du script

Créer le fichier :

```bash
nano /home/scripts/pve-scripts-local-status.sh
```

Coller le **script nettoyé** (voir annexe à la fin de ce README), puis sauvegarder.

Rendre le script exécutable :

```bash
chmod +x /home/scripts/pve-scripts-local-status.sh
```

### 4.3. Répertoires de travail

Le script utilise automatiquement :

- Pour l’état / baseline :
  - `/var/lib/pve-scripts-local/`
- Pour les logs :
  - `/var/log/pve-scripts-local/`

Ils sont créés si nécessaire.

---

## 5. Test manuel

Lancer un test :

```bash
/home/scripts/pve-scripts-local-status.sh
```

À la fin :

- Un fichier log doit apparaître dans :
  - `/var/log/pve-scripts-local/`
- Un message doit être visible dans le canal Discord :
  - avec un **résumé** dans le texte ;
  - et le **log complet** en pièce jointe.

---

## 6. Planification quotidienne à 06h00

Pour lancer ce check **tous les jours à 06h00**, ajouter une entrée `cron` :

```bash
crontab -e
```

Ajouter la ligne suivante :

```cron
0 6 * * * /home/scripts/pve-scripts-local-status.sh >/dev/null 2>&1
```

Explication :
- `0 6 * * *` → tous les jours à **06h00**.
- La sortie standard et les erreurs sont ignorées (`>/dev/null 2>&1`), le détail étant dans le log et dans Discord.

---

## 7. Emplacement des fichiers générés

- **Baseline des scripts** :
  - `/var/lib/pve-scripts-local/scripts_baseline.txt`

- **Logs** :
  - `/var/log/pve-scripts-local/pve-scripts-local_status_YYYY-MM-DDTHH-MM-SS+ZZZZ.log`

Ces fichiers peuvent être sauvegardés ou copiés dans une procédure de backup si nécessaire.

---

## 8. Réinitialiser la baseline

Si tu veux repartir d’un état “propre” (par exemple après un gros changement de scripts), tu peux supprimer la baseline :

```bash
rm -f /var/lib/pve-scripts-local/scripts_baseline.txt
```

Lors de la prochaine exécution du script :

- Tous les scripts actuels seront considérés comme **nouvelle baseline**.
- Le résumé Discord indiquera une **initialisation**.

---

## 9. Annexe : Script complet (nettoyé)

> ⚠️ **Important :** ce script est **nettoyé** :  
> - L’URL du webhook Discord est mise sous forme de **placeholder**.  
> - Aucun code sensible, aucun e-mail réel, aucune donnée privée.

Pense à remplacer `"<DISCORD_WEBHOOK_URL>"` par ton URL réelle.
