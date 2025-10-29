# DBLens MVP - Database Analytics API

A plug-and-play database analytics API that provides schema introspection, query validation, and secure read-only query execution across multiple database types.

## Features

- **Multi-Database Support**: PostgreSQL, MySQL, and Snowflake connectors
- **Schema Introspection**: Automatic discovery of tables, columns, and sample data
- **Query Validation**: SQL query analysis and cost estimation
- **Secure Execution**: Read-only query execution with audit logging
- **Health Monitoring**: Built-in health checks and API status monitoring
- **Interactive Documentation**: Auto-generated API docs with Swagger UI

## Quick Start

### Prerequisites

- Docker and Docker Compose
- Python 3.11+ (for local development)
- curl and jq (for testing)

### 1. Clone and Setup

```bash
git clone <your-repo-url>
cd Data266_GroupProject/dblens-mvp-starter

# Create environment file (if not exists)
cp .env.example .env  # Edit as needed
```

### 2. Bootstrap the Application

Run the bootstrap script to set up the entire stack:

```bash
bash scripts/bootstrap.sh
```

This script will:
- Build and start Docker containers (PostgreSQL, API, Ingester)
- Wait for PostgreSQL to be healthy
- Create database roles and permissions
- Set up system tables
- Create required application tables (`connections`, `schema_card_cache`)
- Verify API connectivity

### 3. Verify Installation

After bootstrap completes, verify the API is running:

```bash
# Test root endpoint (should return API information)
curl -s http://localhost:8000/ | jq .

# Test health check
curl -s http://localhost:8000/health | jq .

# Access interactive documentation
open http://localhost:8000/docs
```

Expected root endpoint response:
```json
{
  "service": "DBLens MVP",
  "version": "1.0.0",
  "description": "Plug & Play Database Analytics API",
  "docs_url": "/docs",
  "health_url": "/health",
  "endpoints": {
    "connections": "/connections",
    "schema": "/schema/cards",
    "preview": "/preview",
    "validate": "/validate",
    "approve": "/approve",
    "datasets": "/datasets/from-url"
  }
}
```

## API Endpoints

### Core Endpoints

- `GET /` - API information and endpoint directory
- `GET /health` - Health check with database connectivity status
- `GET /docs` - Interactive API documentation

### Database Connections

- `POST /connections` - Add new database connection
- `GET /connections` - List all connections
- `POST /connections/test` - Test connection validity

### Schema Discovery

- `GET /schema/cards` - Get schema information with sample data

### Query Operations

- `POST /preview` - Preview query results (limited rows)
- `POST /validate` - Validate SQL and get execution plan
- `POST /approve` - Execute read-only query with audit logging

### Data Ingestion

- `POST /datasets/from-url` - Ingest data from URL

## Usage Examples

### 1. Ingest Sample Data

```bash
make ingest URL="https://people.sc.fsu.edu/~jburkardt/data/csv/airtravel.csv" TABLE=airtravel FORMAT=csv ARGS="--if-exists replace"
```

### 2. Explore Schema

```bash
curl -s http://localhost:8000/schema/cards | jq .
```

### 3. Preview Query Results

```bash
curl -s http://localhost:8000/preview \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT COUNT(*) FROM airtravel"}' | jq .
```

### 4. Validate Query

```bash
curl -s http://localhost:8000/validate \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT * FROM airtravel LIMIT 5"}' | jq .
```

### 5. Execute Query with Audit

```bash
curl -s http://localhost:8000/approve \
  -H 'Content-Type: application/json' \
  -d '{"sql":"SELECT * FROM airtravel LIMIT 5","question":"Sample data check"}' | jq .
```

### 6. Add External Database Connection

```bash
curl -s http://localhost:8000/connections \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "My PostgreSQL DB",
    "driver": "postgres",
    "dsn": "postgresql://user:pass@host:5432/dbname"
  }' | jq .
```

## Architecture

### Components

- **API Service**: FastAPI application with database connectors
- **PostgreSQL**: Primary database for metadata and audit logs
- **Ingester**: Data ingestion service for CSV/JSON files
- **Connectors**: Pluggable database drivers (PostgreSQL, MySQL, Snowflake)

### Database Schema

The application uses several system tables:

- `connections`: External database connection configurations
- `schema_card_cache`: Cached schema information for performance
- `audit_events`: Query execution audit trail
- `ingestion_log`: Data ingestion provenance records

### Security Model

- **Read-Only Execution**: All query operations are read-only by default
- **Role-Based Access**: Separate database roles for read (`app_ro`) and write (`loader_rw`) operations
- **Query Timeouts**: Configurable timeouts to prevent long-running queries
- **Audit Logging**: All query executions are logged with metadata

## Development

### Local Development Setup

```bash
# Install Python dependencies
pip install -r requirements.txt

# Run API locally (requires PostgreSQL running)
cd services/ingester
uvicorn api:app --reload --host 0.0.0.0 --port 8000
```

### Environment Variables

Key environment variables in `.env`:

```bash
# Database connections
APP_RO_DSN=postgresql://app_ro:app_ro_pass@localhost:5432/dblens
LOADER_RW_DSN=postgresql://loader_rw:loader_rw_pass@localhost:5432/dblens

# API configuration
API_HOST=0.0.0.0
API_PORT=8000
```

### Testing

```bash
# Run health check script
bash scripts/health_check_v6.sh

# Test all endpoints
bash scripts/test_api.sh  # If available
```

## Troubleshooting

### Common Issues

1. **API returns 404 on root endpoint**
   - Ensure the bootstrap script completed successfully
   - Check that all required database tables exist
   - Verify API container is running: `docker compose ps`

2. **Empty reply from server (ERR_EMPTY_RESPONSE)**
   - Check API container logs: `docker compose logs api`
   - Ensure database tables are created
   - Restart API container: `docker compose restart api`

3. **Database connection errors**
   - Verify PostgreSQL is healthy: `docker compose ps postgres`
   - Check database roles exist: `docker compose exec postgres psql -U postgres -d dblens -c "\du"`
   - Verify environment variables in `.env`

4. **Missing tables error**
   - Run the table creation commands:
   ```bash
   docker compose exec -T postgres psql -U postgres -d dblens -c "
   CREATE TABLE IF NOT EXISTS connections (
     id bigserial PRIMARY KEY,
     name text NOT NULL,
     driver text NOT NULL,
     dsn text,
     secret_ref text,
     features_json jsonb DEFAULT '{}',
     read_only_verified boolean DEFAULT false,
     created_at timestamptz DEFAULT now(),
     last_tested_at timestamptz
   );
   
   CREATE TABLE IF NOT EXISTS schema_card_cache (
     conn_id bigint NOT NULL,
     table_fqn text NOT NULL,
     columns_json jsonb,
     samples_json jsonb,
     refreshed_at timestamptz DEFAULT now(),
     PRIMARY KEY (conn_id, table_fqn)
   );
   
   GRANT SELECT ON connections TO app_ro;
   GRANT INSERT, SELECT, UPDATE ON connections TO loader_rw;
   GRANT USAGE, SELECT ON SEQUENCE connections_id_seq TO loader_rw;
   GRANT SELECT ON schema_card_cache TO app_ro;
   GRANT INSERT, SELECT, UPDATE ON schema_card_cache TO loader_rw;
   "
   ```

### Logs and Debugging

```bash
# View API logs
docker compose logs api -f

# View PostgreSQL logs
docker compose logs postgres -f

# Check container status
docker compose ps

# Restart services
docker compose restart api
docker compose restart postgres
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

[Your License Here]

## Support

For issues and questions:
- Check the troubleshooting section above
- Review API documentation at `http://localhost:8000/docs`
- Check container logs for error details