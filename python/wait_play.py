import os
import time
import sys
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.desired_capabilities import DesiredCapabilities
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

def get_driver() -> webdriver.Chrome:
    """
    Returns a Chrome WebDriver instance.
    Prefers a manually installed chromedriver at /usr/local/bin/chromedriver;
    falls back to Selenium Manager-managed driver if not found.
    """
    chrome_options = Options()
    chrome_options.add_argument("--disable-extensions")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--window-size=1920,1080")
    chrome_options.add_argument("--headless=new")

    chromedriver_path = "/usr/local/bin/chromedriver"
    if os.path.exists(chromedriver_path):
        service = Service(executable_path=chromedriver_path)
        return webdriver.Chrome(service=service, options=chrome_options)
    else:
        # Selenium Manager will handle downloading the correct driver
        return webdriver.Chrome(options=chrome_options)

def try_access_page_and_click(url: str) -> None:
    driver = get_driver()
    start = time.time()
    max_duration = 3 * 60  # 3 minutes

    try:
        while time.time() - start < max_duration:
            try:
                driver.get(url)
                WebDriverWait(driver, 10).until(
                    EC.element_to_be_clickable((By.CSS_SELECTOR, ".green-button"))
                )
                # click green → red three times
                for _ in range(3):
                    driver.find_element(By.CSS_SELECTOR, ".green-button").click()
                    WebDriverWait(driver, 10).until(
                        EC.element_to_be_clickable((By.CSS_SELECTOR, ".red-button"))
                    ).click()
                    time.sleep(1)

                driver.quit()
                print("Clicked button 3 times!")
                return

            except Exception as e:
                print(f"Attempt failed: {e!r}, retrying in 20s…")
                time.sleep(20)

        driver.quit()
        sys.exit(1)

    except Exception as e:
        print(f"Unexpected error: {e!r}")
        driver.quit()
        sys.exit(1)


if __name__ == "__main__":
    base_url = os.getenv("APP_BASE_URL", "http://localhost:4000/play")
    try_access_page_and_click(base_url)
