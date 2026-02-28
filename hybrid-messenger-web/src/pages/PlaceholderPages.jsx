// Placeholder pages - will be developed in later phases

export function HomePage() {
    return (
        <div style={{ padding: '2rem', textAlign: 'center' }}>
            <h1>🏠 Home Feed</h1>
            <p>Coming in Phase 4</p>
        </div>
    );
}

export function MessagesPage() {
    return (
        <div style={{ padding: '2rem', textAlign: 'center' }}>
            <h1>💬 Messages</h1>
            <p>Coming in Phase 2</p>
        </div>
    );
}

export function SearchPage() {
    return (
        <div style={{ padding: '2rem', textAlign: 'center' }}>
            <h1>🔍 Search & Discovery</h1>
            <p>Coming in Phase 3</p>
        </div>
    );
}

export function AccountPage({ onLogout }) {
    return (
        <div style={{ padding: '2rem', textAlign: 'center' }}>
            <h1>⚙️ Account Settings</h1>
            <p>Coming in Phase 5</p>
            <br />
            <button onClick={onLogout} className="btn btn-primary">
                Logout
            </button>
        </div>
    );
}

export default { HomePage, MessagesPage, SearchPage, AccountPage };
