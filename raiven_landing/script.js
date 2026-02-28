/* ═══════════════════════════════════════════════════════════════
   RAVEN Landing — Liquid Glass Interactive JS
   Particle mesh · Route diagram · Scroll reveals · Micro-interactions
   ═══════════════════════════════════════════════════════════════ */

document.addEventListener('DOMContentLoaded', () => {

    // ═══════════════════ MESH PARTICLE CANVAS ═══════════════════
    const canvas = document.getElementById('meshCanvas');
    if (canvas) {
        const ctx = canvas.getContext('2d');
        let mouseX = -1000, mouseY = -1000;
        let particles = [];
        const PARTICLE_COUNT = 45;
        const CONNECTION_DIST = 130;
        const MOUSE_DIST = 160;

        function resizeCanvas() {
            canvas.width = window.innerWidth;
            canvas.height = window.innerHeight;
        }
        resizeCanvas();
        window.addEventListener('resize', resizeCanvas);

        class Particle {
            constructor() {
                this.x = Math.random() * canvas.width;
                this.y = Math.random() * canvas.height;
                this.vx = (Math.random() - 0.5) * 0.25;
                this.vy = (Math.random() - 0.5) * 0.25;
                this.radius = Math.random() * 1.5 + 0.5;
            }
            update() {
                this.x += this.vx;
                this.y += this.vy;
                if (this.x < 0 || this.x > canvas.width) this.vx *= -1;
                if (this.y < 0 || this.y > canvas.height) this.vy *= -1;
                // Mouse attraction
                const dx = mouseX - this.x, dy = mouseY - this.y;
                const dist = Math.sqrt(dx * dx + dy * dy);
                if (dist < MOUSE_DIST) {
                    this.x += dx * 0.005;
                    this.y += dy * 0.005;
                }
            }
            draw() {
                ctx.beginPath();
                ctx.arc(this.x, this.y, this.radius, 0, Math.PI * 2);
                ctx.fillStyle = 'rgba(200, 169, 106, 0.4)';
                ctx.fill();
            }
        }

        for (let i = 0; i < PARTICLE_COUNT; i++) particles.push(new Particle());

        function animateMesh() {
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            particles.forEach(p => { p.update(); p.draw(); });
            // Connections
            for (let i = 0; i < particles.length; i++) {
                for (let j = i + 1; j < particles.length; j++) {
                    const dx = particles[i].x - particles[j].x;
                    const dy = particles[i].y - particles[j].y;
                    const dist = Math.sqrt(dx * dx + dy * dy);
                    if (dist < CONNECTION_DIST) {
                        ctx.beginPath();
                        ctx.moveTo(particles[i].x, particles[i].y);
                        ctx.lineTo(particles[j].x, particles[j].y);
                        ctx.strokeStyle = `rgba(200, 169, 106, ${0.08 * (1 - dist / CONNECTION_DIST)})`;
                        ctx.lineWidth = 0.5;
                        ctx.stroke();
                    }
                }
            }
            requestAnimationFrame(animateMesh);
        }
        animateMesh();

        document.addEventListener('mousemove', (e) => {
            mouseX = e.clientX;
            mouseY = e.clientY;
        });
    }

    // ═══════════════════ SCROLL PROGRESS BAR ═══════════════════
    const scrollProgress = document.getElementById('scrollProgress');
    function updateScrollProgress() {
        if (!scrollProgress) return;
        const scrollTop = window.scrollY;
        const docHeight = document.documentElement.scrollHeight - window.innerHeight;
        scrollProgress.style.width = (scrollTop / docHeight * 100) + '%';
    }

    // ═══════════════════ NAVBAR ═══════════════════
    const nav = document.getElementById('nav');
    function updateNav() {
        if (!nav) return;
        nav.classList.toggle('scrolled', window.scrollY > 50);
    }

    // ═══════════════════ MOBILE MENU ═══════════════════
    const navToggle = document.getElementById('navToggle');
    const mobileMenu = document.getElementById('mobileMenu');
    if (navToggle && mobileMenu) {
        navToggle.addEventListener('click', () => {
            navToggle.classList.toggle('active');
            mobileMenu.classList.toggle('open');
        });
        // Close on link click
        mobileMenu.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', () => {
                navToggle.classList.remove('active');
                mobileMenu.classList.remove('open');
            });
        });
    }

    // ═══════════════════ SMOOTH SCROLL FOR ANCHORS ═══════════════════
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', (e) => {
            const href = anchor.getAttribute('href');
            if (href === '#') return;
            const target = document.querySelector(href);
            if (target) {
                e.preventDefault();
                const top = target.offsetTop - 70;
                window.scrollTo({ top, behavior: 'smooth' });
            }
        });
    });

    // ═══════════════════ SCROLL REVEALS ═══════════════════
    const fadeElements = document.querySelectorAll('.fade-in');
    const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    if (prefersReducedMotion) {
        fadeElements.forEach(el => el.classList.add('visible'));
    } else {
        const revealObserver = new IntersectionObserver((entries) => {
            entries.forEach((entry) => {
                if (entry.isIntersecting) {
                    entry.target.classList.add('visible');
                    revealObserver.unobserve(entry.target);
                }
            });
        }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
        fadeElements.forEach(el => revealObserver.observe(el));
    }

    // ═══════════════════ COMBINED SCROLL HANDLER ═══════════════════
    let ticking = false;
    window.addEventListener('scroll', () => {
        if (!ticking) {
            requestAnimationFrame(() => {
                updateScrollProgress();
                updateNav();
                ticking = false;
            });
            ticking = true;
        }
    }, { passive: true });
    updateScrollProgress();
    updateNav();

    // ═══════════════════ INTERACTIVE ROUTE DIAGRAM ═══════════════════
    const diagramToggles = document.querySelectorAll('.diagram-toggle');
    const pathOnline1 = document.getElementById('pathOnline1');
    const pathOnline2 = document.getElementById('pathOnline2');
    const pathDirect = document.getElementById('pathDirect');
    const pathBridge1 = document.getElementById('pathBridge1');
    const pathBridge2 = document.getElementById('pathBridge2');
    const pathBridge3 = document.getElementById('pathBridge3');
    const routeBadgeText = document.getElementById('routeBadgeText');
    const cloudNode = document.getElementById('cloudNode');
    const relayNode = document.getElementById('relayNode');

    function setDiagramMode(mode) {
        const allPaths = [pathOnline1, pathOnline2, pathDirect, pathBridge1, pathBridge2, pathBridge3];
        allPaths.forEach(p => { if (p) { p.classList.remove('active'); p.style.opacity = '0.15'; } });

        // Reset node opacity
        if (cloudNode) cloudNode.style.opacity = '0.3';
        if (relayNode) relayNode.style.opacity = '0.3';

        if (mode === 'online') {
            [pathOnline1, pathOnline2].forEach(p => { if (p) { p.classList.add('active'); p.style.opacity = '1'; } });
            if (cloudNode) cloudNode.style.opacity = '1';
            if (routeBadgeText) routeBadgeText.textContent = 'via Server';
        } else if (mode === 'offline') {
            if (pathDirect) { pathDirect.classList.add('active'); pathDirect.style.opacity = '1'; }
            if (routeBadgeText) routeBadgeText.textContent = 'via Direct Mesh';
        } else if (mode === 'bridge') {
            [pathBridge1, pathBridge2, pathBridge3].forEach(p => { if (p) { p.classList.add('active'); p.style.opacity = '1'; } });
            if (cloudNode) cloudNode.style.opacity = '1';
            if (relayNode) relayNode.style.opacity = '1';
            if (routeBadgeText) routeBadgeText.textContent = 'via Bridge Relay';
        }
    }

    diagramToggles.forEach(btn => {
        btn.addEventListener('click', () => {
            diagramToggles.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            setDiagramMode(btn.dataset.mode);
        });
    });

    // Initialize diagram
    setDiagramMode('online');

    // ═══════════════════ GLASS CARD GLOW TRACKING ═══════════════════
    document.querySelectorAll('.glass').forEach(card => {
        card.addEventListener('mousemove', function (e) {
            const rect = this.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const y = e.clientY - rect.top;
            this.style.setProperty('--glow-x', x + 'px');
            this.style.setProperty('--glow-y', y + 'px');
            this.style.background = `
                radial-gradient(300px circle at ${x}px ${y}px, rgba(200,169,106,0.06), transparent 60%),
                rgba(255,255,255,0.06)
            `;
        });
        card.addEventListener('mouseleave', function () {
            this.style.background = 'rgba(255,255,255,0.06)';
        });
    });

    // ═══════════════════ BUTTON RIPPLE ═══════════════════
    document.querySelectorAll('.btn-primary, .btn-secondary').forEach(btn => {
        btn.addEventListener('click', function (e) {
            const rect = this.getBoundingClientRect();
            const x = e.clientX - rect.left;
            const y = e.clientY - rect.top;
            const ripple = document.createElement('span');
            ripple.style.cssText = `
                position: absolute; border-radius: 50%;
                background: rgba(255,255,255,0.3);
                width: 0; height: 0; left: ${x}px; top: ${y}px;
                transform: translate(-50%, -50%);
                animation: rippleEffect 0.6s ease-out forwards;
                pointer-events: none;
            `;
            this.style.position = 'relative';
            this.style.overflow = 'hidden';
            this.appendChild(ripple);
            setTimeout(() => ripple.remove(), 600);
        });
    });

    // Add ripple keyframes
    const style = document.createElement('style');
    style.textContent = `
        @keyframes rippleEffect {
            to { width: 200px; height: 200px; opacity: 0; }
        }
    `;
    document.head.appendChild(style);

    // ═══════════════════ FAQ ACCORDION ═══════════════════
    document.querySelectorAll('.faq-question').forEach(btn => {
        btn.addEventListener('click', () => {
            const item = btn.closest('.faq-item');
            const wasOpen = item.classList.contains('open');
            // Close all
            document.querySelectorAll('.faq-item.open').forEach(i => i.classList.remove('open'));
            // Toggle current
            if (!wasOpen) item.classList.add('open');
        });
    });

    // ═══════════════════ CONSOLE BRANDING ═══════════════════
    console.log(
        '%c🐦‍⬛ RAVEN %c Messaging that survives outages.',
        'background:linear-gradient(135deg,#C8A96A,#E8D5A8);color:#0B0D12;padding:8px 14px;border-radius:6px 0 0 6px;font-weight:bold;font-size:13px;',
        'background:#111;color:#666;padding:8px 14px;border-radius:0 6px 6px 0;font-size:13px;'
    );
});
