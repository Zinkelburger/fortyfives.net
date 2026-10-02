"""Play a real four-player game and check phone layouts and touch interactions.

    python python/mobile_check.py --url http://localhost:4000 --out artifacts/mobile

Uses private lobbies and isolated browser sessions; never adds public-queue bots.
Run against a local/test instance. Screenshots keep the requested viewport height.
"""
import argparse
import json
import time
from pathlib import Path

from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait

from tbot import get_driver, live_socket_connected

SIZES = [(320, 480), (320, 568), (360, 640), (390, 844), (430, 932),
         (600, 800), (601, 800), (568, 320), (844, 390), (1400, 900)]


class MobileCheck:
    def __init__(self, url, out):
        self.url = url.rstrip('/')
        self.out = out
        self.out.mkdir(parents=True, exist_ok=True)
        self.drivers = []
        self.checked = set()
        self.measurements = []

    def wait(self, fn):
        return WebDriverWait(self.drivers[0], 20, poll_frequency=.1).until(lambda _: fn())

    def viewport(self, d, w=390, h=844):
        d.execute_cdp_cmd('Emulation.setDeviceMetricsOverride',
                             {'width': w, 'height': h, 'deviceScaleFactor': 1, 'mobile': w < 1000})
        d.execute_cdp_cmd('Emulation.setTouchEmulationEnabled', {'enabled': w < 1000})
        d.execute_script('window.scrollTo(0, 0)')

    def click(self, d, selector):
        self.wait(lambda: d.find_element(By.CSS_SELECTOR, selector).is_enabled())
        d.find_element(By.CSS_SELECTOR, selector).click()

    def state(self, d):
        return d.execute_script("return document.querySelector('#game-container')?.dataset || {}")

    def selected(self, d):
        return json.loads(d.find_element(By.ID, 'player-hand').get_attribute('data-selected-cards') or '[]')

    def capture(self, d, name):
        d.save_screenshot(str(self.out / f'{name}.png'))

    def layout(self, d, label, w, h, vertical=True):
        self.viewport(d, w, h)
        time.sleep(.08)
        result = d.execute_script('''
          const controls = [...document.querySelectorAll(
            '#game-container button, #game-container a, #player-hand img, .table img')];
          return controls.filter(e => e.getClientRects().length).map(e => {
            const r=e.getBoundingClientRect();
            const hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);
            return {name:e.id||e.getAttribute('aria-label')||e.textContent.trim(),
              x:r.x,y:r.y,right:r.right,bottom:r.bottom,w:r.width,h:r.height,
              hit:hit===e || e.contains(hit), disabled:e.disabled,
              control:e.matches('button,a')};
          });
        ''')
        for e in result:
            assert e['x'] >= -1 and e['right'] <= w + 1, (label, w, h, 'horizontal', e)
            if vertical:
                assert e['y'] >= -1 and e['bottom'] <= h + 1, (label, w, h, 'vertical', e)
                if not e.get('disabled'):
                    assert e['hit'], (label, w, h, 'covered', e)
            if e['control'] and not e.get('disabled'):
                assert e['w'] >= 43 and e['h'] >= 43, (label, 'touch target', e)
        self.measurements.append({'phase': label, 'width': w, 'height': h, 'elements': result})
        if (w, h) in [(390, 844), (844, 390), (1400, 900)]:
            self.capture(d, f'{label}-{w}')

    def matrix(self, d, phase):
        for w, h in SIZES:
            self.layout(d, phase, w, h)
        self.viewport(d)
        self.checked.add(phase)
        print('PASS viewport matrix:', phase, flush=True)

    def dialog_matrix(self, d, label, fits=False):
        for w, h in SIZES:
            self.viewport(d, w, h)
            panel = d.find_element(By.CLASS_NAME, 'game-dialog-panel').rect
            if fits and h >= 568:
                # Short enough to read whole on a phone, without scrolling.
                body = d.execute_script("const b = document.querySelector('.dialog-body'); return [b.scrollHeight, b.clientHeight]")
                assert body[0] <= body[1] + 1, (label, w, h, 'dialog scrolls', body)
            assert panel['x'] >= 0 and panel['x'] + panel['width'] <= w + 1, (label, w, h, panel)
            assert panel['y'] >= 0 and panel['y'] + panel['height'] <= h + 1, (label, w, h, panel)
            assert d.execute_script('''
              const close = document.querySelector('#close-score-overlay');
              const r = close.getBoundingClientRect();
              return close.contains(document.elementFromPoint(r.x + r.width/2, r.y + r.height/2));
            '''), (label, w, h, 'Close is covered')
        self.viewport(d)
        print('PASS dialog matrix:', label, flush=True)

    def enter(self):
        for i in range(4):
            d = get_driver()
            self.drivers.append(d)
            self.viewport(d)
            d.get(self.url + '/play?tab=private' if i == 0 else lobby)
            self.wait(lambda: live_socket_connected(d))
            if i == 0:
                self.click(d, '#create-private-button')
                self.wait(lambda: '/play/private/' in d.current_url)
                lobby = d.current_url
            # Navigation can resolve before the new view has mounted.
            time.sleep(.4)
            self.click(d, '#join-queue-button')
            self.wait(lambda: '/game/' in d.current_url or bool(d.find_elements(By.ID, 'leave-queue-button')))
        for d in self.drivers:
            self.wait(lambda: '/game/' in d.current_url and self.state(d).get('phase'))

    def discard_checks(self, d):
        self.matrix(d, 'discard-eight')
        buttons = d.find_elements(By.CSS_SELECTOR, 'button[data-card]')
        for button in buttons:
            button.click()
            assert button.get_attribute('aria-pressed') == 'true'
            button.click()
        for button in buttons[:5]:
            button.click()
        keep = self.selected(d)
        buttons[7].click()
        assert self.selected(d) == keep
        assert 'Deselect' in d.find_element(By.ID, 'selection-summary').text
        for button in buttons[:5]:
            button.click()
        buttons[7].send_keys(Keys.SPACE)
        assert len(self.selected(d)) == 1
        buttons[7].send_keys(Keys.SPACE)
        for button in buttons[:3]:
            button.click()
        self.capture(d, 'discard-selected-390')
        keep = self.selected(d)
        self.viewport(d, 844, 390)
        assert self.selected(d) == keep
        self.viewport(d)
        self.click(d, '#open-scores')
        self.wait(lambda: bool(d.find_elements(By.ID, 'game-dialog')))
        assert d.execute_script("return document.activeElement.id") == 'close-score-overlay'
        self.dialog_matrix(d, 'scores')
        # A different player's server update must not unlock the modal backdrop.
        other = next(p for p in self.drivers if p != d and self.state(p).get('confirmDiscardClicked') != 'true')
        self.click(other, 'button[data-card]')
        self.click(other, '#confirm-discard-button')
        self.wait(lambda: self.state(other).get('confirmDiscardClicked') == 'true')
        assert d.execute_script("document.querySelector('#open-scores').focus(); return !!document.activeElement.closest('#game-dialog')")
        assert self.selected(d) == keep
        close = d.find_element(By.ID, 'close-score-overlay')
        r = close.rect
        assert r['x'] + r['width'] <= 390 and r['y'] + r['height'] <= 844
        # Reverse tab from Close wraps into the score history, not the table.
        close.send_keys(Keys.SHIFT, Keys.TAB)
        assert d.execute_script("return !!document.activeElement.closest('#game-dialog')")
        self.capture(d, 'scores-390')
        d.switch_to.active_element.send_keys(Keys.ESCAPE)
        self.wait(lambda: not d.find_elements(By.ID, 'game-dialog'))
        assert d.execute_script("return document.activeElement.id") == 'open-scores'
        assert self.selected(d) == keep
        self.click(d, '#open-rules')
        self.wait(lambda: bool(d.find_elements(By.CLASS_NAME, 'quick-rules')))
        self.dialog_matrix(d, 'rules', fits=True)
        self.click(d, '#close-score-overlay')
        self.wait(lambda: not d.find_elements(By.ID, 'game-dialog'))
        for button in d.find_elements(By.CSS_SELECTOR, 'button[data-card][aria-pressed="true"]'):
            button.click()
        print('PASS selection, keep limit, keyboard, rotation, dialogs', flush=True)

    def play(self):
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            phase = self.state(self.drivers[0]).get('phase')
            if phase == 'Final Scoring':
                for d in self.drivers:
                    self.wait(lambda: self.state(d).get('phase') == 'Final Scoring')
                self.matrix(self.drivers[0], 'final-scoring')
                self.click(self.drivers[0], '[phx-click="exit_game"]')
                self.wait(lambda: '/play' in self.drivers[0].current_url)
                print('PASS complete game and return to lobby', flush=True)
                return
            if phase == 'Scoring':
                if 'scoring' not in self.checked:
                    self.layout(self.drivers[0], 'scoring', 390, 844)
                    self.checked.add('scoring')
                time.sleep(.1)
                continue
            if phase == 'Discard':
                if 'discard-eight' not in self.checked:
                    winner = self.wait(lambda: next((d for d in self.drivers if len(d.find_elements(By.CSS_SELECTOR, 'button[data-card]')) == 8), None))
                    self.discard_checks(winner)
                for d in self.drivers:
                    state = self.state(d)
                    if state.get('phase') != 'Discard' or state.get('confirmDiscardClicked') == 'true':
                        continue
                    cards = d.find_elements(By.CSS_SELECTOR, 'button[data-card]')
                    if len(cards) == 8 and 'discard-eight' not in self.checked:
                        self.discard_checks(d)
                    elif len(cards) == 5 and 'discard-five' not in self.checked:
                        self.matrix(d, 'discard-five')
                    cards = d.find_elements(By.CSS_SELECTOR, 'button[data-card]')
                    for card in cards[:5]:
                        card.click()
                    self.wait(lambda: len(self.selected(d)) == 5)
                    self.click(d, '#confirm-discard-button')
                    self.wait(lambda: self.state(d).get('confirmDiscardClicked') == 'true' or self.state(d).get('phase') != 'Discard')
                continue
            current = next((d for d in self.drivers if self.state(d).get('currentTurn') == 'true'), None)
            if current is None:
                time.sleep(.05)
                continue
            state = self.state(current)
            if state.get('phase') == 'Bidding':
                if 'bidding' not in self.checked:
                    self.matrix(current, 'bidding')
                if state.get('currentBid') != '0' and 'bidding-standing' not in self.checked:
                    self.matrix(current, 'bidding-standing')
                if state.get('currentBid') == '0' or state.get('bagged') == 'true':
                    self.click(current, '[phx-value-bid-number="15"]')
                    self.click(current, '[phx-value-bid-suit="hearts"]')
                    self.click(current, '#confirm-bid-button')
                else:
                    self.click(current, '#pass-bid-button')
                    self.wait(lambda: 'Confirm Pass' in current.find_element(By.ID, 'confirm-bid-button').text)
                    self.click(current, '#confirm-bid-button')
                self.wait(lambda: self.state(current).get('currentTurn') != 'true' or self.state(current).get('phase') != 'Bidding')
            elif state.get('phase') == 'Playing':
                if 'playing' not in self.checked:
                    self.matrix(current, 'playing')
                if 'playing-trick' not in self.checked and len(current.find_elements(By.CSS_SELECTOR, '.table img')) == 3:
                    # The fourth player has not moved yet, so this trick stays
                    # put while we check actual played cards at every size.
                    self.matrix(current, 'playing-trick')
                if 'reconnect' not in self.checked:
                    self.click(current, 'button[data-card]:not(:disabled)')
                    assert len(self.selected(current)) == 1
                    current.execute_script('window.liveSocket.disconnect()')
                    self.wait(lambda: not live_socket_connected(current))
                    self.wait(lambda: current.find_element(By.ID, 'play-card-button').get_attribute('disabled') is not None)
                    current.execute_script('window.liveSocket.connect()')
                    self.wait(lambda: live_socket_connected(current))
                    self.wait(lambda: self.selected(current) == [])
                    for close in current.find_elements(By.CSS_SELECTOR, '#flash-info button'):
                        close.click()
                    self.checked.add('reconnect')
                    print('PASS socket disconnect and reconnect clears stale selection', flush=True)
                    continue

                cards = current.find_elements(By.CSS_SELECTOR, 'button[data-card]:not(:disabled)')
                if not cards:
                    time.sleep(.05)
                    continue
                version = current.find_element(By.ID, 'player-hand').get_attribute('data-selection-version')
                # Right after a reconnect the hand stays locked until the
                # server confirms state, so a tap can be ignored; tap again.
                card_id = cards[0].get_attribute('id')
                self.wait(lambda: len(self.selected(current)) == 1 or current.find_element(By.ID, card_id).click())
                if 'playing-selected' not in self.checked:
                    self.capture(current, 'playing-selected-390')
                    self.checked.add('playing-selected')
                self.click(current, '#play-card-button')
                self.wait(lambda: self.state(current).get('phase') != 'Playing' or current.find_element(By.ID, 'player-hand').get_attribute('data-selection-version') != version)
        raise AssertionError('Game did not finish in ten minutes')

    def run(self):
        try:
            self.enter()
            self.play()
        except Exception:
            for i, d in enumerate(self.drivers):
                self.capture(d, f'failure-{i}')
                (self.out / f'failure-{i}.html').write_text(d.page_source)
            raise
        finally:
            (self.out / 'measurements.json').write_text(json.dumps(self.measurements, indent=2))
            for d in self.drivers:
                d.quit()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://localhost:4000')
    parser.add_argument('--out', type=Path, default=Path('artifacts/mobile'))
    args = parser.parse_args()
    MobileCheck(args.url, args.out).run()
