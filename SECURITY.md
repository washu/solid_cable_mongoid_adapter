# Security Policy

## Supported Versions

We release patches for security vulnerabilities in the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |
| < 1.0   | :x:                |

## Reporting a Vulnerability

We take the security of SolidCableMongoidAdapter seriously. If you believe you have found a security vulnerability, please report it to us as described below.

### Please Do Not

- **Do not** open a public GitHub issue for security vulnerabilities
- **Do not** discuss the vulnerability in public forums, social media, or mailing lists until it has been addressed

### How to Report

**Email**: Send details to [sscotto@gmail.com](mailto:sscotto@gmail.com)

**Subject line**: `[SECURITY] SolidCableMongoidAdapter: Brief Description`

**Include**:
1. Description of the vulnerability
2. Steps to reproduce the issue
3. Potential impact
4. Suggested fix (if available)
5. Your contact information for follow-up

### What to Expect

- **Acknowledgment**: We will acknowledge receipt of your vulnerability report within 48 hours
- **Assessment**: We will assess the vulnerability and determine its severity within 5 business days
- **Updates**: We will keep you informed of our progress toward a fix
- **Credit**: We will credit you in the security advisory (unless you prefer to remain anonymous)
- **Disclosure**: Once a fix is available, we will:
  1. Release a patched version
  2. Publish a security advisory on GitHub
  3. Notify users through appropriate channels

### Response Timeline

- **Critical vulnerabilities**: Patch within 7 days
- **High severity**: Patch within 30 days
- **Medium/Low severity**: Patch in next regular release

## Security Best Practices

When using SolidCableMongoidAdapter in production:

### MongoDB Security

1. **Use Replica Sets**: Always configure MongoDB as a replica set with authentication enabled
2. **Network Security**:
   - Use TLS/SSL for MongoDB connections
   - Restrict MongoDB network access using firewalls
   - Use VPC/private networks in cloud environments
3. **Authentication**: Enable MongoDB authentication with strong passwords
4. **Authorization**: Use role-based access control (RBAC)
5. **Audit Logging**: Enable MongoDB audit logs for compliance

### Configuration Security

```yaml
production:
  adapter: solid_mongoid
  # Use environment variables for sensitive configuration
  # Never commit credentials to version control
```

### Connection String Security

```ruby
# config/mongoid.yml
production:
  clients:
    default:
      # Use ENV variables, never hardcode credentials
      uri: <%= ENV['MONGODB_URI'] %>
      options:
        # Enable TLS/SSL
        ssl: true
        ssl_verify: true
        ssl_cert: <%= ENV['MONGODB_CERT_PATH'] %>
        ssl_key: <%= ENV['MONGODB_KEY_PATH'] %>
        ssl_ca_cert: <%= ENV['MONGODB_CA_CERT_PATH'] %>
```

### Application Security

1. **Input Validation**: Always validate and sanitize channel names and message payloads
2. **Authorization**: Implement proper authorization checks in your Action Cable channels
3. **Rate Limiting**: Implement rate limiting for WebSocket connections
4. **Monitoring**: Monitor for unusual patterns in message volume or subscription activity

### Data Security

1. **Message Expiration**: Configure appropriate TTL values to avoid data retention issues
2. **Sensitive Data**: Avoid broadcasting sensitive information; encrypt if necessary
3. **Collection Access**: Restrict access to the Action Cable messages collection

### Example Secure Configuration

```ruby
# config/cable.yml
production:
  adapter: solid_mongoid
  collection_name: "action_cable_messages"
  expiration: 300  # 5 minutes - adjust based on your needs
  require_replica_set: true  # Enforce replica set requirement

# config/mongoid.yml
production:
  clients:
    default:
      uri: <%= ENV['MONGODB_URI'] %>
      options:
        max_pool_size: 50
        min_pool_size: 5
        ssl: true
        ssl_verify: true
        auth_source: admin
        replica_set: rs0
        read:
          mode: :primary_preferred
        write:
          w: 1
```

## Known Security Considerations

### Message Persistence

Messages are persisted in MongoDB with TTL-based expiration. Ensure your `expiration` setting aligns with your data retention policies and compliance requirements.

### Resume Token Storage

Resume tokens are stored in memory only and are lost on process restart. This is by design to prevent replay attacks and ensure clean state on restart.

### Change Stream Permissions

The MongoDB user must have appropriate permissions for Change Streams:
- `find` on the collection
- `changeStream` on the database

### Polling Fallback Mode

When Change Streams are unavailable, the adapter falls back to polling. This mode is less efficient and should not be used in production. Always use a replica set configuration.

## Security Audit History

- **2025-02**: Initial security review completed
- No known vulnerabilities at this time

## Related Security Documentation

- [MongoDB Security Checklist](https://docs.mongodb.com/manual/administration/security-checklist/)
- [Action Cable Security](https://guides.rubyonrails.org/action_cable_overview.html#security)
- [Mongoid Configuration](https://www.mongodb.com/docs/mongoid/current/reference/configuration/)

## Questions?

If you have questions about security that are not sensitive in nature, please open a public GitHub issue with the `security` label.

For sensitive security concerns, always use the private reporting method described above.
