import os
import sys

from selenium import webdriver
from selenium.common.exceptions import TimeoutException
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

QUEUE_READY_TIMEOUT_SECONDS = 180
ACTION_TIMEOUT_SECONDS = 30


def get_driver() -> webdriver.Chrome:
    """Return a headless Chrome driver for CI and local smoke checks."""
    chrome_options = Options()
    chrome_options.add_argument("--disable-dev-shm-usage")
    chrome_options.add_argument("--disable-extensions")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--headless=new")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--window-size=1920,1080")

    chromedriver_path = "/usr/local/bin/chromedriver"
    if os.path.exists(chromedriver_path):
        service = Service(executable_path=chromedriver_path)
        return webdriver.Chrome(service=service, options=chrome_options)

    return webdriver.Chrome(options=chrome_options)


def live_socket_connected(driver: webdriver.Chrome) -> bool:
    return bool(
        driver.execute_script(
            """
            return Boolean(
                window.liveSocket &&
                typeof window.liveSocket.isConnected === "function" &&
                window.liveSocket.isConnected()
            )
            """
        )
    )


def verify_queue_ready(url: str) -> None:
    driver = get_driver()

    try:
        driver.get(url)
        wait = WebDriverWait(driver, QUEUE_READY_TIMEOUT_SECONDS)
        wait.until(EC.presence_of_element_located((By.ID, "queue-root")))
        wait.until(live_socket_connected)
        print("Queue LiveView is connected.")

        WebDriverWait(driver, ACTION_TIMEOUT_SECONDS).until(
            EC.element_to_be_clickable((By.ID, "join-queue-button"))
        ).click()

        WebDriverWait(driver, ACTION_TIMEOUT_SECONDS).until(
            EC.presence_of_element_located((By.ID, "leave-queue-button"))
        )

        WebDriverWait(driver, ACTION_TIMEOUT_SECONDS).until(
            EC.element_to_be_clickable((By.ID, "leave-queue-button"))
        ).click()

        WebDriverWait(driver, ACTION_TIMEOUT_SECONDS).until(
            EC.presence_of_element_located((By.ID, "join-queue-button"))
        )

        print("Queue page is ready and join/leave works.")
    except TimeoutException as error:
        print(f"Queue smoke check timed out: {error!r}")
        sys.exit(1)
    finally:
        driver.quit()


if __name__ == "__main__":
    verify_queue_ready(os.getenv("APP_BASE_URL", "http://localhost:4000/play"))
