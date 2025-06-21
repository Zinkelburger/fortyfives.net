import time
import sys
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

def try_access_page_and_click(url: str) -> None:
    # --- set up Selenium Manager + ChromeOptions ---
    options = Options()
    options.add_argument("--disable-extensions")
    options.add_argument("--disable-gpu")
    options.add_argument("--no-sandbox")
    options.add_argument("--window-size=1920,1080")
    options.add_argument("--headless")

    # no Service(...) / chromedriver path needed
    driver = webdriver.Chrome(options=options)

    start = time.time()
    max_duration = 3 * 60  # 3 minutes

    try:
        while time.time() - start < max_duration:
            try:
                driver.get(url)
                # wait for the green-button
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
                print("Clicked button 5 times!")
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
    try_access_page_and_click("http://localhost:4000/play")
