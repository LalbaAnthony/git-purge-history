# git-purge-history

Supprime des fichiers ou dossiers de **tout l'historique** d'un dépôt Git distant, avec une sauvegarde complète, une vérification automatique et un push forcé protégé. Basé sur [git-filter-repo](https://github.com/newren/git-filter-repo), l'outil recommandé par le projet Git pour réécrire l'historique.

Les commandes sont séparées pour qu'il y ait toujours un point de contrôle humain avant toute action sur le serveur :

| Commande          | Effet                                                                                                | Touche au serveur ?   |
| ----------------- | ---------------------------------------------------------------------------------------------------- | --------------------- |
| `analyze`         | Rapport de taille de l'historique d'un clone local                                                   | Non                   |
| `rewrite`         | Clone miroir (sauvegarde), réécriture d'une copie, vérification                                      | Non (lecture seule)   |
| `verify`          | Relance la vérification d'une réécriture                                                             | Non                   |
| `push`            | Push forcé des branches et tags réécrits                                                             | **Oui**               |
| `update-checkout` | Bascule une copie déployée (prod) sur le nouvel historique en gardant les fichiers purgés sur disque | Non (fetch seulement) |

## Prérequis

- bash ≥ 4 (sous Windows : **Git Bash**), Git ≥ 2.36.
- git-filter-repo : `pip install git-filter-repo` (Windows : `py -m pip install --user git-filter-repo`). Vérifier avec `git filter-repo --version`. Si git ne le trouve pas, ajouter au `PATH` le dossier des scripts Python utilisateur, que donne `py -c "import sysconfig; print(sysconfig.get_path('scripts', 'nt_user'))"` (par exemple `C:\Users\<user>\AppData\Roaming\Python\Python314\Scripts`). Dans Git Bash, ajouter à `~/.bashrc` : `export PATH="$PATH:/c/Users/<user>/AppData/Roaming/Python/Python314/Scripts"`.
- De la place disque pour un clone miroir complet du dépôt.
- Lancer les tests une fois sur la machine : `./test.sh` (dépôt synthétique dans un dossier temporaire, aucun accès réseau).

## Procédure

### 0. Décider quoi purger (lecture seule)

Dans un clone à jour du dépôt :

```bash
git fetch --all --prune
git-purge-history.sh analyze --repo . --depth 2 --top 20
```

La section « paths absent from HEAD » liste ce qui ne pèse plus que dans l'historique : on peut le purger sans rien changer au code actuel. Un chemin encore présent dans `HEAD` (par exemple `uploads/`) disparaîtra aussi du dépôt actuel. Il faut donc décider avant où vivront ces fichiers (stockage partagé, rsync depuis la prod…) et comment les environnements de dev les récupèrent.

### 1. Préparer

1. Le chemin à purger doit être dans le `.gitignore` racine de la branche par défaut, commité et poussé **avant** la réécriture. Sinon `rewrite` affiche un avertissement, et le dossier finira par être recommité.
2. Annoncer un gel des pushs. Chacun pousse les branches qu'il veut garder : une branche restée locale devra être portée à la main après coup (voir étape 4).
3. Autoriser temporairement le push forcé sur les branches protégées (GitLab : Settings > Repository > Protected branches > « Allowed to force push »). Sinon le push est refusé ; comme il est atomique, rien n'est modifié dans ce cas.
4. Sauvegarder les fichiers des copies déployées (`tar`/`rsync` de `uploads/` par exemple) avant l'étape 4.

### 2. Réécrire et vérifier (rien n'est poussé)

```bash
git-purge-history.sh rewrite \
  --url git@serveur:groupe/projet.git \
  --workdir ../purge-projet \
  --path uploads --path vmlinuz
```

Les chemins sont relatifs à la racine du dépôt : `uploads` supprime `uploads/` à la racine, pas `src/uploads/`, `uploads2/` ni `uploads.txt`. Une liste peut être passée avec `--paths-file` (un chemin par ligne, `#` pour les commentaires). Un chemin introuvable dans l'historique arrête tout (faute de frappe, casse) ; tous les chemins introuvables sont listés d'un coup.

Pour purger un dossier en gardant certains de ses fichiers (par exemple les `.gitkeep` qui créent son arborescence), passer avec `--paths-file` la liste de tous les chemins qu'il a contenus dans l'historique, sauf ceux à garder. À générer dans un clone à jour, ou dans le `work.git` d'une réécriture déjà poussée :

```bash
for c in $(git rev-list --all --full-history -- files); do git ls-tree -r -z --name-only "$c" -- files; done | tr '\0' '\n' | sort -u | grep -v '/\.gitkeep$' > files-sans-gitkeep.txt
```

La vérification prouve ensuite que les fichiers gardés n'ont pas changé. Le contrôle des chemins parcourt l'historique une fois par chemin, avant et après la réécriture : compter quelques minutes par millier de chemins.

Contenu du `--workdir` :

- `backup.git` : clone miroir intact du serveur, **à garder jusqu'à la fin**.
- `work.git` : la copie réécrite.
- `original-refs.txt` : état des branches et tags au moment de la sauvegarde.
- `dropped-refs.txt` : refs hors `refs/heads` et `refs/tags` (merge requests, notes…), ni réécrites ni poussées.
- `filter-repo.log`, `paths.txt`, `verified.ok`.

La vérification, relançable avec `verify --workdir ...`, contrôle :

- qu'aucun chemin purgé ne subsiste dans une branche ou un tag ;
- que chaque branche et chaque tag existe toujours et contient exactement les mêmes fichiers (mêmes blobs, mêmes modes) qu'avant, moins les chemins purgés. Aucun autre fichier n'a donc été modifié ni perdu ;
- le nombre de commits et la taille, avant et après. Les commits qui ne touchaient que des chemins purgés disparaissent ;
- les plus gros blobs restants, pour repérer un oubli. Dans ce cas, relancer `rewrite` dans un **nouveau** workdir.

### 3. Pousser

```bash
git-purge-history.sh push --workdir ../purge-projet
```

- Le script refuse si une branche ou un tag a bougé sur le serveur depuis la sauvegarde (nouveau commit, branche créée ou supprimée). Dans ce cas, relancer `rewrite` dans un nouveau workdir une fois le gel effectif.
- Chaque ref est poussée avec `--force-with-lease` sur sa valeur attendue : un push concurrent pendant l'opération fait échouer le push au lieu d'être écrasé.
- Le push est atomique, par lots de 100 refs.
- Le script demande de taper `PUSH` (`--yes` en non interactif).
- Il est relançable après une coupure : les refs déjà réécrites sur le serveur sont ignorées.
- Après le push, le script contrôle que le serveur est identique à `work.git`.

### 4. Après le push

1. **Nettoyage serveur** : les anciens objets restent stockés côté serveur tant qu'il ne les a pas supprimés.
   - GitLab : Settings > Repository > Repository cleanup, téléverser `<workdir>/work.git/filter-repo/commit-map`.
   - Gitea/Forgejo : Administration > Maintenance > ramasse-miettes, ou `git gc` sur le serveur.
   - Dépôt nu en SSH : `git reflog expire --expire=now --all && git gc --prune=now` dans le dépôt.
   - GitHub : contacter le support (refs de pull requests, vues en cache).
2. Rétablir la protection des branches.
3. **Chaque développeur supprime son clone et reclone.** Ne jamais pousser depuis un ancien clone : cela renverrait tout l'ancien historique. Si cela arrive, une relance de `push --workdir ...` le détecte (« was created/updated on the remote since the snapshot »). Pour récupérer du travail non poussé depuis un ancien clone : `git format-patch origin/master..ma-branche -o ../patches`, puis `git am ../patches/*.patch` dans le nouveau clone.
4. **Copies déployées** (prod, préprod) qu'on ne peut pas simplement recloner :

   ```bash
   git-purge-history.sh update-checkout --repo /var/www/projet --path uploads --path vmlinuz --gc
   ```

   Le script refuse s'il y a des modifications locales sur des fichiers suivis hors chemins purgés, ou si le serveur n'a pas encore été réécrit. Sinon, il retire les chemins de l'index sans toucher aux fichiers sur disque, puis fait un `fetch` et un `reset --hard` sur l'upstream réécrit. Il contrôle ensuite que le nombre de fichiers sur disque n'a pas baissé. `--gc` libère la place de l'ancien historique.

   `update-checkout` n'est pas prévu pour une longue liste de chemins : au-delà de quelques centaines, la ligne de commande dépasse la limite de Windows et le contrôle des refs locales devient très lent. Dans ce cas, mettre de côté les fichiers purgés, recloner, puis les remettre en place.
5. Garder `backup.git` quelques semaines, puis supprimer le workdir.

## Effets de bord à connaître

- Tous les SHA de commits changent à partir du premier commit modifié. Les liens vers des commits (tickets, CI, documentation) sont cassés, et les merge requests ou pull requests ouvertes sont à recréer.
- Les signatures GPG des commits réécrits sont perdues.
- Les refs hors `refs/heads` et `refs/tags` (merge requests, notes, keep-around…) ne sont ni réécrites ni supprimées. Elles maintiennent l'ancien historique côté serveur jusqu'au nettoyage serveur.
- Hors périmètre : la suppression par taille (`git filter-repo --strip-blobs-bigger-than`) et le remplacement de contenu, par exemple des secrets (`--replace-text`). Ces opérations ne sont pas couvertes par la vérification de ce script.

## Message pour l'équipe (à adapter)

> L'historique du dépôt `<projet>` va être réécrit le `<date>` à `<heure>` pour en retirer `<chemins>` (le dépôt passe de `<avant>` à `<après>`). Avant cette heure, poussez toutes les branches que vous voulez garder ; ensuite, plus aucun push jusqu'à nouvel ordre. Une fois l'opération terminée : supprimez votre clone et reclonez. Ne poussez jamais depuis un ancien clone, cela réintroduirait tout l'ancien historique. Les merge requests ouvertes seront à recréer. `<chemins>` ne sont plus dans Git : récupérez-les via `<méthode>`.
