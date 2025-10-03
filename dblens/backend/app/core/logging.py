from loguru import logger
import os


def init_logging():
    os.makedirs("logs", exist_ok=True)
    logger.remove()
    logger.add(
        "logs/dblens.jsonl",
        format="{message}",
        serialize=True,
        enqueue=True,
        rotation="10 MB",
        retention="7 days",
        backtrace=False,
        diagnose=False,
        level="INFO",
    )
