"""Trivial interactive 'nc' challenge. Prints the per-instance flag on success.
The flag comes from the FLAG env var injected by the instancer."""
import os
import random
import sys

FLAG = os.environ.get("FLAG", "flag{unset}")


def main():
    print("=== Guess the number (1-100). You get 7 tries. ===", flush=True)
    target = random.randint(1, 100)
    for t in range(7):
        sys.stdout.write(f"[{7 - t} left] guess> ")
        sys.stdout.flush()
        line = sys.stdin.readline()
        if not line:
            break
        try:
            g = int(line.strip())
        except ValueError:
            print("not a number", flush=True)
            continue
        if g == target:
            print(f"Correct! Here is your flag: {FLAG}", flush=True)
            return
        print("higher" if g < target else "lower", flush=True)
    print(f"Out of tries. It was {target}. Try again!", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (EOFError, KeyboardInterrupt):
        pass
