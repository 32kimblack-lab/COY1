# COY Backend Server

Backend server for serving user profile pages at `https://coy.services/{username}`.

## Features

- User profile pages with public collections
- Responsive design matching the app's aesthetic
- Only displays public collections (private collections are hidden)
- Shows collection previews with post thumbnails
- SEO-friendly with Open Graph meta tags

## Setup

### 1. Install Dependencies

```bash
npm install
```

### 2. Firebase Admin SDK Setup

You need to set up Firebase Admin SDK credentials. Choose one of the following methods:

#### Option 1: Service Account Key File (Recommended for Development)

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Select your project
3. Go to Project Settings > Service Accounts
4. Click "Generate New Private Key"
5. Save the JSON file as `serviceAccountKey.json` in the `backend` directory

#### Option 2: Environment Variable (Recommended for Production)

1. Get your service account JSON (same as Option 1)
2. Set it as an environment variable:
   ```bash
   export FIREBASE_SERVICE_ACCOUNT='{"type":"service_account",...}'
   ```

Or add it to your `.env` file:
```
FIREBASE_SERVICE_ACCOUNT={"type":"service_account",...}
```

### 3. Configure Environment Variables

Copy `.env.example` to `.env` and update with your settings:

```bash
cp .env.example .env
```

Edit `.env` and add your configuration.

### 4. Run the Server

#### Development (with auto-reload):
```bash
npm run dev
```

#### Production:
```bash
npm start
```

The server will run on port 3000 by default (or the port specified in `PORT` environment variable).

## Routes

### Profile by Username
- **URL**: `https://coy.services/{username}`
- **Example**: `https://coy.services/johndoe`
- **Description**: Displays the user's profile page with public collections

### Profile by User ID
- **URL**: `https://coy.services/profile/{userId}`
- **Example**: `https://coy.services/profile/abc123xyz`
- **Description**: Alternative route using user ID instead of username

### Health Check
- **URL**: `/health`
- **Description**: Returns server status

## Deployment

### Deploy to Vercel

1. Install Vercel CLI:
   ```bash
   npm i -g vercel
   ```

2. Deploy:
   ```bash
   vercel
   ```

3. Set environment variables in Vercel dashboard:
   - `FIREBASE_SERVICE_ACCOUNT` (your service account JSON)

### Deploy to Heroku

1. Create a Heroku app:
   ```bash
   heroku create coy-backend
   ```

2. Set environment variables:
   ```bash
   heroku config:set FIREBASE_SERVICE_ACCOUNT='{"type":"service_account",...}'
   ```

3. Deploy:
   ```bash
   git push heroku main
   ```

### Deploy to DigitalOcean/Railway/Render

Follow their respective documentation for Node.js deployments. Make sure to:
- Set `FIREBASE_SERVICE_ACCOUNT` environment variable
- Set `PORT` environment variable (if required)
- Install dependencies: `npm install`
- Start command: `npm start`

## Domain Configuration

To use `https://coy.services`:

1. Point your domain's DNS to your server's IP address
2. Set up SSL certificate (Let's Encrypt recommended)
3. Configure reverse proxy (nginx recommended) to forward requests to port 3000

### Nginx Configuration Example

```nginx
server {
    listen 80;
    server_name coy.services www.coy.services;
    
    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
```

## Security Notes

- **NEVER commit `serviceAccountKey.json` to version control**
- Use environment variables for production
- Keep your Firebase service account credentials secure
- Regularly rotate service account keys
- Use HTTPS in production

## Troubleshooting

### Firebase Admin SDK Not Initialized

- Check that your service account credentials are correct
- Verify the credentials have proper Firestore read permissions
- Check console logs for specific error messages

### Collections Not Showing

- Verify collections have `isPublic: true` in Firestore
- Check Firestore security rules allow read access
- Verify the user has collections in the database

### Images Not Loading

- Check that image URLs are valid and accessible
- Verify Firebase Storage rules allow public read access
- Check browser console for CORS errors

## License

ISC

