# RAIVEN Website

Official website for RAIVEN - Revolutionary communication technology combining cloud messaging with mesh networking.

## 🌐 Live Demo

Visit: [Coming Soon]

## 📋 Features

- **Modern Design**: Glassmorphism effects, gradient animations, and premium aesthetics
- **Fully Responsive**: Optimized for desktop, tablet, and mobile devices
- **Interactive**: Smooth animations, parallax effects, and dynamic content
- **SEO Optimized**: Proper meta tags, semantic HTML, and fast loading times
- **Accessibility**: ARIA labels, keyboard navigation, and screen reader friendly

## 🚀 Quick Start

### Local Development

1. Navigate to the website directory:
```bash
cd hybrid_messenger_website
```

2. Open the website:
```bash
# macOS
open index.html

# Or use a local server (recommended)
python3 -m http.server 8000
# Then visit: http://localhost:8000
```

## 🌍 Domain Setup & Deployment

### Option 1: Netlify (Recommended - Free)

1. **Sign up** at [netlify.com](https://netlify.com)

2. **Deploy via Drag & Drop:**
   - Open Netlify Dashboard
   - Drag the `hybrid_messenger_website` folder into the deploy area
   - Your site will be live at: `random-name.netlify.app`

3. **Set up custom domain:**
   - In Netlify Dashboard → Domain Settings
   - Click "Add custom domain"
   - Enter your domain (e.g., `hybridmessenger.com`)
   - Follow DNS configuration instructions:
     ```
     Type: A
     Name: @
     Value: 75.2.60.5
     
     Type: CNAME
     Name: www
     Value: your-site.netlify.app
     ```

4. **Enable HTTPS** (automatic with custom domain)

### Option 2: Vercel

1. **Install Vercel CLI:**
```bash
npm install -g vercel
```

2. **Deploy:**
```bash
cd hybrid_messenger_website
vercel --prod
```

3. **Set up custom domain:**
   - Visit Vercel Dashboard
   - Go to your project → Settings → Domains
   - Add your custom domain
   - Update DNS records as instructed

### Option 3: GitHub Pages

1. **Create a GitHub repository**

2. **Push your website:**
```bash
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/yourusername/hybrid-messenger-website.git
git push -u origin main
```

3. **Enable GitHub Pages:**
   - Go to repository Settings → Pages
   - Source: Deploy from branch `main` → `/root`
   - Save

4. **Custom domain:**
   - Add a `CNAME` file with your domain:
     ```
     hybridmessenger.com
     ```
   - Update DNS records:
     ```
     Type: CNAME
     Name: www
     Value: yourusername.github.io
     
     Type: A
     Name: @
     Values: 
       185.199.108.153
       185.199.109.153
       185.199.110.153
       185.199.111.153
     ```

### Option 4: Traditional Hosting (cPanel/Plesk)

1. **Purchase hosting** from providers like:
   - Namecheap
   - Bluehost
   - HostGator
   - SiteGround

2. **Upload files:**
   - Login to cPanel
   - File Manager → `public_html`
   - Upload all files from `hybrid_messenger_website`

3. **Domain is usually included** with hosting packages

## 🔧 Customization

### Update Content

Edit `index.html` to modify:
- Company name
- Features
- FAQ content
- Contact information
- App Store links

### Change Colors

Edit `styles.css` root variables:
```css
:root {
    --color-primary: #6366f1;
    --color-secondary: #10b981;
    /* ... more colors */
}
```

### Add/Remove Sections

Sections are clearly marked in `index.html`:
```html
<!-- Hero Section -->
<!-- Features Section -->
<!-- FAQ Section -->
etc.
```

## 📱 Update App Store Links

When your app is published, update the links in `index.html`:

```html
<!-- Line ~300 -->
<a href="YOUR_APP_STORE_LINK" class="store-button">
    <!-- App Store button -->
</a>
```

## 🎨 Assets

The website uses:
- **Google Fonts**: Inter
- **Icons**: Unicode emoji (can be replaced with Font Awesome or custom icons)
- **Colors**: Custom gradient system

## 🔍 SEO Checklist

- [x] Meta description
- [x] Semantic HTML
- [x] Heading hierarchy (H1, H2, H3)
- [x] Alt text for images
- [x] Mobile responsive
- [ ] Submit to Google Search Console
- [ ] Create sitemap.xml
- [ ] Add robots.txt

## 📊 Analytics (Optional)

Add Google Analytics by inserting before `</head>`:

```html
<!-- Google tag (gtag.js) -->
<script async src="https://www.googletagmanager.com/gtag/js?id=GA_MEASUREMENT_ID"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'GA_MEASUREMENT_ID');
</script>
```

## 🌐 Buying a Domain

### Recommended Registrars:

1. **Namecheap** (namecheap.com)
   - Affordable
   - Free WhoisGuard privacy
   - Easy DNS management

2. **Google Domains** (domains.google.com)
   - Simple interface
   - Integrated with Google services
   - Transparent pricing

3. **Cloudflare Registrar** (cloudflare.com)
   - At-cost pricing
   - Free SSL
   - Built-in CDN

### Domain Suggestions:
- `hybridmessenger.com`
- `hybrid-messenger.com`
- `hybridmsg.com`
- `hybridmessenger.io`
- `hybridmessenger.app`

### Average Cost:
- `.com` → $10-15/year
- `.io` → $30-40/year
- `.app` → $15-20/year

## 📝 License

© 2026 RAIVEN. All rights reserved.

## 🆘 Support

For questions or issues:
- Email: support@hybridmessenger.com
- Create an issue in this repository

---

**Made with ⚡ by RAIVEN Team**
