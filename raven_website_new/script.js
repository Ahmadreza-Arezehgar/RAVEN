// === RAVEN Website JavaScript - Enhanced with Mesh Map ===

// Mobile Navigation Toggle
const navToggle = document.getElementById('navToggle');
const navMenu = document.querySelector('.nav-menu');

if (navToggle) {
    navToggle.addEventListener('click', () => {
        navMenu.classList.toggle('active');
        navToggle.classList.toggle('active');
    });
}

// Close mobile menu when clicking a link
document.querySelectorAll('.nav-link, .nav-cta').forEach(link => {
    link.addEventListener('click', () => {
        navMenu.classList.remove('active');
        if (navToggle) navToggle.classList.remove('active');
    });
});

// Navbar scroll effect
const navbar = document.querySelector('.navbar');
window.addEventListener('scroll', () => {
    if (window.scrollY > 60) {
        navbar.style.background = 'rgba(28, 28, 30, 0.85)';
        navbar.style.boxShadow = '0 12px 45px rgba(0, 0, 0, 0.5)';
    } else {
        navbar.style.background = 'rgba(28, 28, 30, 0.45)';
        navbar.style.boxShadow = '0 12px 40px rgba(0, 0, 0, 0.35)';
    }
});

// === Scroll Reveal Animations ===
const observerOptions = { root: null, rootMargin: '0px', threshold: 0.15 };

const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry, index) => {
        if (entry.isIntersecting) {
            setTimeout(() => {
                entry.target.classList.add('visible');
            }, index * 100);
            observer.unobserve(entry.target);
        }
    });
}, observerOptions);

document.querySelectorAll('.animate-on-scroll, .feature-card, .case-card, .step-item').forEach((el, index) => {
    el.style.transitionDelay = `${index * 0.05}s`;
    observer.observe(el);
});

// Smooth scroll for anchor links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function (e) {
        e.preventDefault();
        const target = document.querySelector(this.getAttribute('href'));
        if (target) {
            const navHeight = navbar.offsetHeight + 30;
            window.scrollTo({
                top: target.getBoundingClientRect().top + window.scrollY - navHeight,
                behavior: 'smooth'
            });
        }
    });
});

// === Animated Counter ===
function animateCounter(element, target, suffix = '') {
    const duration = 2000;
    const start = 0;
    const startTime = performance.now();

    function update(currentTime) {
        const elapsed = currentTime - startTime;
        const progress = Math.min(elapsed / duration, 1);
        const easeOut = 1 - Math.pow(1 - progress, 3);
        const current = Math.floor(start + (target - start) * easeOut);
        element.textContent = current;
        if (progress < 1) requestAnimationFrame(update);
    }
    requestAnimationFrame(update);
}

// Trigger counters when stats section is visible
const statsObserver = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
        if (entry.isIntersecting) {
            document.querySelectorAll('.stat-number[data-count]').forEach(num => {
                animateCounter(num, parseInt(num.dataset.count));
            });
            statsObserver.unobserve(entry.target);
        }
    });
}, { threshold: 0.5 });

const heroStats = document.querySelector('.hero-stats');
if (heroStats) statsObserver.observe(heroStats);

// === Interactive Mesh Network Canvas ===
class MeshNetwork {
    constructor(canvas) {
        this.canvas = canvas;
        this.ctx = canvas.getContext('2d');
        this.nodes = [];
        this.connections = [];
        this.messages = [];
        this.resize();

        window.addEventListener('resize', () => this.resize());
        this.init();
        this.animate();
    }

    resize() {
        this.canvas.width = this.canvas.offsetWidth * window.devicePixelRatio;
        this.canvas.height = this.canvas.offsetHeight * window.devicePixelRatio;
        this.ctx.scale(window.devicePixelRatio, window.devicePixelRatio);
        this.width = this.canvas.offsetWidth;
        this.height = this.canvas.offsetHeight;
    }

    init() {
        // Create nodes
        const nodeCount = Math.min(25, Math.floor(this.width / 50));
        for (let i = 0; i < nodeCount; i++) {
            this.nodes.push({
                x: Math.random() * this.width,
                y: Math.random() * this.height,
                vx: (Math.random() - 0.5) * 0.5,
                vy: (Math.random() - 0.5) * 0.5,
                radius: Math.random() * 4 + 4,
                type: Math.random() > 0.7 ? 'relay' : 'active',
                pulse: Math.random() * Math.PI * 2
            });
        }

        // Update stats
        document.getElementById('nodeCount').textContent = nodeCount;
    }

    updateConnections() {
        this.connections = [];
        const maxDist = 120;

        for (let i = 0; i < this.nodes.length; i++) {
            for (let j = i + 1; j < this.nodes.length; j++) {
                const dx = this.nodes[i].x - this.nodes[j].x;
                const dy = this.nodes[i].y - this.nodes[j].y;
                const dist = Math.sqrt(dx * dx + dy * dy);

                if (dist < maxDist) {
                    this.connections.push({
                        from: this.nodes[i],
                        to: this.nodes[j],
                        opacity: 1 - (dist / maxDist)
                    });
                }
            }
        }

        document.getElementById('connectionCount').textContent = this.connections.length;
    }

    spawnMessage() {
        if (this.connections.length > 0 && Math.random() > 0.95) {
            const conn = this.connections[Math.floor(Math.random() * this.connections.length)];
            this.messages.push({
                from: { x: conn.from.x, y: conn.from.y },
                to: { x: conn.to.x, y: conn.to.y },
                progress: 0,
                speed: 0.02 + Math.random() * 0.02
            });
        }
    }

    update() {
        // Move nodes
        for (const node of this.nodes) {
            node.x += node.vx;
            node.y += node.vy;
            node.pulse += 0.03;

            // Bounce off edges
            if (node.x < 20 || node.x > this.width - 20) node.vx *= -1;
            if (node.y < 20 || node.y > this.height - 20) node.vy *= -1;

            // Keep in bounds
            node.x = Math.max(20, Math.min(this.width - 20, node.x));
            node.y = Math.max(20, Math.min(this.height - 20, node.y));
        }

        this.updateConnections();
        this.spawnMessage();

        // Update messages
        this.messages = this.messages.filter(msg => {
            msg.progress += msg.speed;
            return msg.progress < 1;
        });

        // Update message count
        const messageRate = Math.floor(Math.random() * 20 + 80);
        document.getElementById('messageCount').textContent = messageRate;
    }

    draw() {
        this.ctx.clearRect(0, 0, this.width, this.height);

        // Draw connections
        for (const conn of this.connections) {
            this.ctx.beginPath();
            this.ctx.moveTo(conn.from.x, conn.from.y);
            this.ctx.lineTo(conn.to.x, conn.to.y);

            const gradient = this.ctx.createLinearGradient(
                conn.from.x, conn.from.y, conn.to.x, conn.to.y
            );
            gradient.addColorStop(0, `rgba(78, 171, 247, ${conn.opacity * 0.4})`);
            gradient.addColorStop(1, `rgba(139, 92, 246, ${conn.opacity * 0.4})`);

            this.ctx.strokeStyle = gradient;
            this.ctx.lineWidth = 1.5;
            this.ctx.stroke();
        }

        // Draw nodes
        for (const node of this.nodes) {
            const pulseSize = Math.sin(node.pulse) * 2;
            const color = node.type === 'relay' ? '#8B5CF6' : '#4EABF7';

            // Glow
            this.ctx.beginPath();
            this.ctx.arc(node.x, node.y, node.radius + pulseSize + 8, 0, Math.PI * 2);
            this.ctx.fillStyle = `${color}20`;
            this.ctx.fill();

            // Node
            this.ctx.beginPath();
            this.ctx.arc(node.x, node.y, node.radius + pulseSize, 0, Math.PI * 2);
            this.ctx.fillStyle = color;
            this.ctx.fill();
        }

        // Draw messages
        for (const msg of this.messages) {
            const x = msg.from.x + (msg.to.x - msg.from.x) * msg.progress;
            const y = msg.from.y + (msg.to.y - msg.from.y) * msg.progress;

            this.ctx.beginPath();
            this.ctx.arc(x, y, 4, 0, Math.PI * 2);
            this.ctx.fillStyle = '#30D158';
            this.ctx.fill();

            // Trail
            this.ctx.beginPath();
            this.ctx.arc(x, y, 8, 0, Math.PI * 2);
            this.ctx.fillStyle = 'rgba(48, 209, 88, 0.3)';
            this.ctx.fill();
        }
    }

    animate() {
        this.update();
        this.draw();
        requestAnimationFrame(() => this.animate());
    }
}

// Initialize mesh canvas
const meshCanvas = document.getElementById('meshCanvas');
if (meshCanvas) {
    new MeshNetwork(meshCanvas);
}

// === Particle Background ===
function createParticles() {
    const container = document.getElementById('particles');
    if (!container) return;

    for (let i = 0; i < 20; i++) {
        const particle = document.createElement('div');
        const size = Math.random() * 4 + 2;
        const opacity = Math.random() * 0.3 + 0.1;

        particle.style.cssText = `
            position: absolute;
            width: ${size}px;
            height: ${size}px;
            background: rgba(78, 171, 247, ${opacity});
            border-radius: 50%;
            top: ${Math.random() * 100}%;
            left: ${Math.random() * 100}%;
            animation: floatParticle ${Math.random() * 15 + 10}s ease-in-out infinite;
            animation-delay: ${Math.random() * 5}s;
            box-shadow: 0 0 ${size * 2}px rgba(78, 171, 247, ${opacity * 0.5});
        `;
        container.appendChild(particle);
    }
}

const particleStyle = document.createElement('style');
particleStyle.textContent = `
    @keyframes floatParticle {
        0% { transform: translateY(0) translateX(0); opacity: 0; }
        10% { opacity: 1; }
        90% { opacity: 1; }
        100% { transform: translateY(-100vh) translateX(${Math.random() * 60 - 30}px); opacity: 0; }
    }
`;
document.head.appendChild(particleStyle);
createParticles();

// === Feature Card Hover Effects ===
document.querySelectorAll('.feature-card').forEach(card => {
    card.addEventListener('mouseenter', function () {
        const glow = this.querySelector('.icon-glow');
        if (glow) {
            glow.style.transform = 'translate(-50%, -50%) scale(1.5)';
            glow.style.opacity = '1';
        }
    });

    card.addEventListener('mouseleave', function () {
        const glow = this.querySelector('.icon-glow');
        if (glow) {
            glow.style.transform = 'translate(-50%, -50%) scale(1)';
            glow.style.opacity = '0.5';
        }
    });
});

// === Button Press Effects ===
document.querySelectorAll('.btn-primary, .btn-secondary, .store-btn, .nav-cta').forEach(btn => {
    btn.addEventListener('mousedown', function () {
        this.style.transform = 'scale(0.96)';
    });
    btn.addEventListener('mouseup', function () {
        this.style.transform = '';
    });
    btn.addEventListener('mouseleave', function () {
        this.style.transform = '';
    });
});

// === Parallax Effect ===
window.addEventListener('scroll', () => {
    const scrolled = window.scrollY;

    if (scrolled < window.innerHeight) {
        const visual = document.querySelector('.hero-visual');
        const content = document.querySelector('.hero-content');

        if (visual) visual.style.transform = `translateY(${scrolled * 0.1}px)`;
        if (content) {
            content.style.transform = `translateY(${scrolled * 0.05}px)`;
            content.style.opacity = 1 - (scrolled / window.innerHeight) * 0.5;
        }
    }
});

// === Cursor Glow (Desktop Only) ===
if (window.matchMedia('(min-width: 768px)').matches) {
    const cursor = document.createElement('div');
    cursor.style.cssText = `
        position: fixed;
        width: 400px;
        height: 400px;
        background: radial-gradient(circle, rgba(78, 171, 247, 0.1) 0%, rgba(139, 92, 246, 0.05) 40%, transparent 70%);
        pointer-events: none;
        z-index: 0;
        transform: translate(-50%, -50%);
        transition: opacity 0.3s ease;
        opacity: 0;
        filter: blur(40px);
    `;
    document.body.appendChild(cursor);

    let cursorX = 0, cursorY = 0, targetX = 0, targetY = 0;

    document.addEventListener('mousemove', (e) => {
        targetX = e.clientX;
        targetY = e.clientY;
        cursor.style.opacity = '1';
    });

    function animateCursor() {
        cursorX += (targetX - cursorX) * 0.08;
        cursorY += (targetY - cursorY) * 0.08;
        cursor.style.left = cursorX + 'px';
        cursor.style.top = cursorY + 'px';
        requestAnimationFrame(animateCursor);
    }
    animateCursor();

    document.addEventListener('mouseleave', () => cursor.style.opacity = '0');
}

// === Load Animation ===
window.addEventListener('load', () => {
    document.body.classList.add('loaded');

    // Stagger hero elements
    const heroElements = document.querySelectorAll('.hero-content > *');
    heroElements.forEach((el, index) => {
        el.style.opacity = '0';
        el.style.transform = 'translateY(25px)';

        setTimeout(() => {
            el.style.transition = 'opacity 0.7s ease, transform 0.7s cubic-bezier(0.2, 0, 0, 1)';
            el.style.opacity = '1';
            el.style.transform = 'translateY(0)';
        }, 200 + (index * 100));
    });
});

console.log('🦅 RAVEN - Mesh Network Messenger');
