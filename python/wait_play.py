# waits for the button on the play page to be clickable
import time
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import os
import sys

def try_access_page_and_click(url: str) -> None:
    # Setup Selenium WebDriver
    chrome_options = Options()
    chrome_options.add_argument("--disable-extensions")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--window-size=1920,1080")
    chrome_options.add_argument("--headless")
    service = Service(os.path.expanduser("~/chromedriver"))
    driver = webdriver.Chrome(service=service, options=chrome_options)
    
    start_time = time.time()
    max_duration = 3 * 60

    try:
        while time.time() - start_time < max_duration:
            try:
                driver.get(url)
                WebDriverWait(driver, 10).until(
                    EC.presence_of_element_located((By.CSS_SELECTOR, ".green-button"))
                )
                for _ in range(3):
                    button = driver.find_element(By.CSS_SELECTOR, ".green-button")
                    button.click()
                    time.sleep(1)
                    button = WebDriverWait(driver, 10).until(
                        EC.presence_of_element_located((By.CSS_SELECTOR, ".red-button"))
                    )
                    button.click()
                    time.sleep(1)

                driver.quit()
                print("Clicked button 5 times!")
                return
            except Exception as e:
                print(f"Attempt failed: {e}")
                time.sleep(20)
        
        # If the loop completes without successful click, exit with status 1
        driver.quit()
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}")
        driver.quit()
        sys.exit(1)

if __name__ == "__main__":
    try_access_page_and_click("http://localhost:4000/play")
