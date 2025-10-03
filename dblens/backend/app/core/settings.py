from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    PG_HOST: str = "localhost"
    PG_PORT: int = 5432
    PG_DB: str = "demo"
    PG_USER: str = "dblens_ro"
    PG_PASSWORD: str = "dblens_ro_pw"
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")


settings = Settings()
