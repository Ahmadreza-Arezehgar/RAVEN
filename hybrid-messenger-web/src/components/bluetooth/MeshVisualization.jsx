import { useEffect, useRef } from 'react';
import './MeshVisualization.css';

function MeshVisualization({ stats, connectedDevices }) {
    const canvasRef = useRef(null);

    useEffect(() => {
        const canvas = canvasRef.current;
        if (!canvas) return;

        const ctx = canvas.getContext('2d');
        const width = canvas.width = canvas.offsetWidth * 2; // Retina
        const height = canvas.height = canvas.offsetHeight * 2;
        ctx.scale(2, 2);

        // Draw mesh network visualization
        drawMesh(ctx, width / 2, height / 2, connectedDevices);

        // Animation loop
        let animationId;
        const animate = () => {
            drawMesh(ctx, width / 2, height / 2, connectedDevices);
            animationId = requestAnimationFrame(animate);
        };
        animate();

        return () => cancelAnimationFrame(animationId);
    }, [connectedDevices]);

    return (
        <div className="mesh-visualization">
            <div className="mesh-stats">
                <div className="stat-card glass-card">
                    <div className="stat-icon">📡</div>
                    <div className="stat-content">
                        <div className="stat-value">{stats.messagesRelayed}</div>
                        <div className="stat-label">Messages Relayed</div>
                    </div>
                </div>

                <div className="stat-card glass-card">
                    <div className="stat-icon">🔄</div>
                    <div className="stat-content">
                        <div className="stat-value">{stats.hopCount}</div>
                        <div className="stat-label">Avg Hop Count</div>
                    </div>
                </div>

                <div className="stat-card glass-card">
                    <div className="stat-icon">🔗</div>
                    <div className="stat-content">
                        <div className="stat-value">{stats.activeConnections}</div>
                        <div className="stat-label">Active Connections</div>
                    </div>
                </div>
            </div>

            <div className="mesh-canvas-container glass-card">
                <h3>Network Topology</h3>
                <canvas ref={canvasRef} className="mesh-canvas"></canvas>
                {connectedDevices.length === 0 && (
                    <div className="canvas-overlay">
                        <p>Connect to devices to see network visualization</p>
                    </div>
                )}
            </div>

            <div className="mesh-info glass-card">
                <h4>Mesh Routing Algorithm</h4>
                <p><strong>Spray-and-Wait:</strong> Messages are "sprayed" to L nodes, then each node waits until it meets the destination.</p>
                <div className="algorithm-steps">
                    <div className="step">
                        <span className="step-number">1</span>
                        <span>Spray Phase: Distribute to first L peers</span>
                    </div>
                    <div className="step">
                        <span className="step-number">2</span>
                        <span>Wait Phase: Hold until meeting recipient</span>
                    </div>
                    <div className="step">
                        <span className="step-number">3</span>
                        <span>Hop Limit: Max 5 hops to prevent loops</span>
                    </div>
                </div>
            </div>
        </div>
    );
}

// Draw mesh network on canvas
function drawMesh(ctx, centerX, centerY, devices) {
    const width = ctx.canvas.width / 2;
    const height = ctx.canvas.height / 2;

    // Clear canvas
    ctx.clearRect(0, 0, width, height);

    // Draw center node (this device)
    const nodeRadius = 30;
    ctx.beginPath();
    ctx.arc(centerX, centerY, nodeRadius, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(99, 102, 241, 0.8)';
    ctx.fill();
    ctx.strokeStyle = 'rgba(99, 102, 241, 1)';
    ctx.lineWidth = 3;
    ctx.stroke();

    // Draw label
    ctx.fillStyle = '#fff';
    ctx.font = 'bold 16px Inter';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText('You', centerX, centerY);

    // Draw connected devices
    const angleStep = (Math.PI * 2) / Math.max(devices.length, 1);
    const radius = 120;

    devices.forEach((device, i) => {
        const angle = angleStep * i;
        const x = centerX + Math.cos(angle) * radius;
        const y = centerY + Math.sin(angle) * radius;

        // Draw connection line
        ctx.beginPath();
        ctx.moveTo(centerX, centerY);
        ctx.lineTo(x, y);
        ctx.strokeStyle = 'rgba(16, 185, 129, 0.3)';
        ctx.lineWidth = 2;
        ctx.stroke();

        // Draw device node
        ctx.beginPath();
        ctx.arc(x, y, 25, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(16, 185, 129, 0.6)';
        ctx.fill();
        ctx.strokeStyle = 'rgba(16, 185, 129, 1)';
        ctx.lineWidth = 2;
        ctx.stroke();

        // Draw device label
        ctx.fillStyle = '#fff';
        ctx.font = '12px Inter';
        ctx.fillText('📱', x, y);
    });
}

export default MeshVisualization;
