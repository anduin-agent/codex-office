import json
import os
import subprocess


def command(home, config):
    return [os.environ["OFFICE_TEST_PROBE"], str(home), str(config)]


class CollectorProbe:
    def __init__(self, home, config):
        self.process = subprocess.Popen(command(home, config), stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, text=True, encoding="utf-8")

    def request(self, operation, **fields):
        self.process.stdin.write(json.dumps({"operation": operation, **fields}) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"Swift collector exited: {self.process.poll()}")
        return json.loads(line)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.process.stdout.close()
