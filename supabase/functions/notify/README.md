# Notifications push (fonction `notify`)

Quand quelqu'un n'utilise pas l'application, le téléphone reçoit quand même la notification (demande d'ami, message d'encouragement, nouveau message). Trois morceaux :

1. **La base** (`supabase/005_messagerie_complete.sql`, déjà exécuté) décide *quand* notifier et prépare le texte.
2. **Cette fonction** (`index.ts`) envoie la notification à Firebase.
3. **L'application** enregistre le jeton du téléphone et ouvre la bonne page au toucher.

## À faire une seule fois

### 1. Firebase (gratuit, sans carte bancaire)
1. console.firebase.google.com → **Ajouter un projet** (nom : `gymflow`). Désactive Google Analytics si on te le propose.
2. Dans le projet : engrenage → **Paramètres du projet** → **Général** → **Vos applications** → icône **Android**.
   - Nom du package Android : `tn.gymflow.gymflow`
   - Surnom : `GymFlow`. Tu peux **ignorer** les étapes suivantes (téléchargement de `google-services.json`, SDK…) : l'application se configure autrement.
3. Toujours dans **Paramètres du projet → Général**, repère ces quatre valeurs et ajoute-les à `secrets.json` :
   ```json
   "FIREBASE_API_KEY": "AIza…",
   "FIREBASE_APP_ID": "1:1234567890:android:abcdef…",
   "FIREBASE_SENDER_ID": "1234567890",
   "FIREBASE_PROJECT_ID": "gymflow-xxxxx"
   ```
   (`FIREBASE_API_KEY` = « Clé API Web », `FIREBASE_APP_ID` = « ID de l'application », `FIREBASE_SENDER_ID` = « ID de l'expéditeur » / « Numéro du projet », `FIREBASE_PROJECT_ID` = « ID du projet ».)
4. **Paramètres du projet → Comptes de service** → **Générer une nouvelle clé privée** → un fichier `.json` se télécharge. **Ne le colle jamais dans le chat ni dans git.** Si **Cloud Messaging API (V1)** est indiquée « désactivée », active-la (lien dans la même page).

### 2. Supabase
1. **Edge Functions → Deploy a new function → Via Editor** (ou « Create function »).
2. Nom : `notify`. Colle le contenu de `supabase/functions/notify/index.ts`.
3. **Désactive « Verify JWT »** pour cette fonction (la base l'appelle sans jeton), puis **Deploy**.
4. **Edge Functions → Secrets** : crée `FCM_SERVICE_ACCOUNT` et colle **tout le contenu** du fichier `.json` de l'étape 1.4.

### 3. Application
Reconstruis l'application avec `secrets.json` à jour (`flutter build apk --release --dart-define-from-file=secrets.json`). Dans **Mes amis**, la ligne « Notifications » indique si tout est branché.

## Tester
1. Téléphone A (Ahmed) : connecté, fonction Amis activée. Téléphone B (Nour) : idem, **puis ferme l'application de B** (retour à l'accueil, ou balaie-la).
2. Sur A, envoie un message à Nour. B reçoit une notification avec le texte du message (ou « Ahmed vous a écrit » si l'aperçu est masqué dans les réglages).
3. Si rien n'arrive : Supabase → **Edge Functions → notify → Logs**.

## Ce qui est volontaire
- **Pas de doublon** : si la personne utilise l'application (signal de présence récent), aucune notification n'est envoyée.
- **Discussions en silence** : jamais de notification.
- **Aperçu du message** sur l'écran verrouillé : activé par défaut, réglable dans *Mes amis* (« Afficher le texte des messages dans les notifications »).
- Les notifications passent par Google (Firebase Cloud Messaging) : le texte du message y transite le temps de l'envoi.
