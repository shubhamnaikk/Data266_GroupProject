from pydantic import BaseSettings


class Settings(BaseSettings):
    PG_HOST: str = "localhost"
    PG_PORT: int = 5432
    PG_DB: str = "demo"
    PG_USER: str = "dblens_ro"
    PG_PASSWORD: str = "dblens_ro_pw"


settings = Settings(_env_file=".env", _env_file_encoding="utf-8")
