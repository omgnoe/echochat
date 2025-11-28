# Security Policy

## 🔐 Our Commitment

Security is at the core of EchoChat. We take all security reports seriously and appreciate the security research community's efforts in helping us maintain a secure platform.

## 📋 Scope

### In Scope

- End-to-end encryption implementation (X25519, AES-256-GCM)
- Key exchange vulnerabilities
- Authentication/authorization bypasses
- Session management flaws
- WebSocket security issues
- Local data storage security
- Information disclosure
- Cryptographic weaknesses

### Out of Scope

- Denial of Service (DoS) attacks
- Social engineering
- Physical attacks
- Issues in dependencies (report to upstream)
- Issues requiring physical device access
- Theoretical attacks without proof of concept

## 🚨 Reporting a Vulnerability

### DO NOT

- ❌ Open a public GitHub issue
- ❌ Disclose publicly before we've addressed it
- ❌ Exploit vulnerabilities against production systems
- ❌ Access other users' data

### DO

1. **Use GitHub's Private Security Reporting**
   - Go to Security → Report a vulnerability
   - Or email details privately

2. **Include in Your Report**
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)
   - Your contact information

3. **Give Us Time**
   - We aim to respond within 48 hours
   - Please allow up to 90 days for fixes before disclosure

## 🔒 Security Model

### What We Protect

```
┌─────────────────────────────────────────────────────┐
│                    CLIENT SIDE                       │
├─────────────────────────────────────────────────────┤
│  ✓ Private keys never leave device                  │
│  ✓ Messages encrypted before transmission           │
│  ✓ Keys stored in secure enclave/keychain           │
│  ✓ Session tokens are random, not user-identifying  │
└─────────────────────────────────────────────────────┘
                         │
                         │ Only encrypted data
                         ▼
┌─────────────────────────────────────────────────────┐
│                    SERVER SIDE                       │
├─────────────────────────────────────────────────────┤
│  ✓ Zero knowledge of message contents               │
│  ✓ No persistent user data storage                  │
│  ✓ Sessions auto-expire after 3 days                │
│  ✓ Only anonymous tokens, no user tracking          │
└─────────────────────────────────────────────────────┘
```

### Cryptographic Primitives

| Purpose | Algorithm | Notes |
|---------|-----------|-------|
| Key Exchange | X25519 | Curve25519 ECDH |
| Encryption | AES-256-GCM | Authenticated encryption |
| Nonce | 96-bit random | Per-message |
| Key Storage | Platform Keychain | iOS Keychain / Android Keystore |

## 🏆 Recognition

We believe in recognizing security researchers who help us:

- Public acknowledgment (if desired)
- Hall of Fame listing (coming soon)
- We're a small project, but we appreciate your help!

## 📞 Contact

- **GitHub Security Advisory**: Preferred method
- **Response Time**: Within 48 hours

## 📜 Safe Harbor

We support security research conducted in good faith. We will not pursue legal action against researchers who:

- Make a good faith effort to avoid privacy violations
- Do not exploit vulnerabilities beyond proof of concept
- Report vulnerabilities promptly
- Do not disclose issues before they're fixed

Thank you for helping keep EchoChat secure! 🛡️
