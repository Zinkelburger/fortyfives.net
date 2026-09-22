"""Smoke check run before the tbots: the queue page loads and join/leave work."""

import os
import sys

from selenium.common.exceptions import TimeoutException
from selenium.webdriver.common.by import By

from tbot import PhxWeb


def verify_queue_ready(url: str) -> None:
    os.environ.setdefault("TBOT_INSTANCE", "wait_play")
    bot = PhxWeb(url)

    try:
        bot.open_lobby(url)
        bot.join_queue()
        bot.click_until(
            "leave-queue-button",
            lambda: len(bot.driver.find_elements(By.ID, "join-queue-button")) == 1,
            "queue leave acknowledgement",
        )
        print("Queue page is ready and join/leave works.", flush=True)
    except TimeoutException as error:
        print(f"Queue smoke check timed out: {error!r}", flush=True)
        bot.capture_failure_artifacts()
        sys.exit(1)
    finally:
        bot.close_driver()


if __name__ == "__main__":
    verify_queue_ready(os.getenv("APP_BASE_URL", "http://localhost:4000/play"))
