#!/bin/bash

echo "=========================================="
echo "  E-Paper Console & Button Auto-Installer "
echo "=========================================="

# Determine the actual user (even if run with sudo)
USER_NAME=${SUDO_USER:-$(whoami)}
SCRIPT_DIR="/home/$USER_NAME/e-Paper/RaspberryPi_JetsonNano/python/examples"

# Ensure gpiozero is installed
echo "[1/6] Checking dependencies (gpiozero)..."
sudo apt-get install -y python3-gpiozero

echo "[2/6] Generating live_console.py..."
cat << 'EOF' > $SCRIPT_DIR/live_console.py
import os, sys, time, subprocess
from PIL import Image, ImageDraw, ImageFont

if os.geteuid() != 0:
    print("Error: Must run with sudo to access /dev/vcs1")
    sys.exit(1)

base_dir = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
lib_dir = os.path.join(base_dir, 'lib')
if os.path.exists(lib_dir): sys.path.append(lib_dir)

from waveshare_epd import epd2in13_V3

CONSOLE_FILE = '/dev/vcs1'
TTY_DEVICE = '/dev/tty1'
FONT_SIZE = 11
COLS, ROWS = 35, 10

def get_console_size():
    try:
        res = subprocess.run(['stty', 'size', '-F', TTY_DEVICE], capture_output=True, text=True, check=True)
        r, c = res.stdout.strip().split()
        return int(r), int(c)
    except: return 24, 80

def set_console_size(r, c):
    try: subprocess.run(['stty', 'cols', str(c), 'rows', str(r), '-F', TTY_DEVICE], check=True)
    except: pass

def get_virtual_console_text(columns=COLS, rows=ROWS):
    try:
        with open(CONSOLE_FILE, 'rb') as f:
            data = f.read(columns * rows)
            text = data.decode('cp437', errors='replace')
            return [text[i:i+columns] for i in range(0, len(text), columns)]
    except Exception as e: return [f"Error:", str(e)]

def main():
    orig_rows, orig_cols = get_console_size()
    set_console_size(ROWS, COLS)
    
    try:
        epd = epd2in13_V3.EPD()
        epd.init()
        epd.Clear(0xFF)
        epd.displayPartBaseImage(epd.getbuffer(Image.new('1', (epd.height, epd.width), 255)))

        font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', FONT_SIZE)
        refresh_count = 0

        while True:
            if refresh_count % 30 == 0 and refresh_count != 0:
                epd.init()
                epd.displayPartBaseImage(epd.getbuffer(Image.new('1', (epd.height, epd.width), 255)))

            image = Image.new('1', (epd.height, epd.width), 255)
            draw = ImageDraw.Draw(image)

            lines = get_virtual_console_text()
            y_offset = 0
            for line in lines:
                draw.text((2, y_offset), line, font=font, fill=0)
                y_offset += 12 

            epd.displayPartial(epd.getbuffer(image))
            refresh_count += 1
            time.sleep(1)

    except KeyboardInterrupt: pass
    finally:
        set_console_size(orig_rows, orig_cols)
        try: epd2in13_V3.epdconfig.module_exit()
        except: pass
        sys.exit(0)

if __name__ == "__main__":
    main()
EOF

echo "[3/6] Generating shutdown_screen.py..."
cat << 'EOF' > $SCRIPT_DIR/shutdown_screen.py
import os
import sys
from PIL import Image, ImageDraw, ImageFont

base_dir = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
lib_dir = os.path.join(base_dir, 'lib')
if os.path.exists(lib_dir):
    sys.path.append(lib_dir)

from waveshare_epd import epd2in13_V3

def main():
    try:
        epd = epd2in13_V3.EPD()
        epd.init()
        epd.Clear(0xFF) 

        image = Image.new('1', (epd.height, epd.width), 255)
        draw = ImageDraw.Draw(image)

        font_lg = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 20)
        font_sm = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 14)

        draw.text((25, 30), "SYSTEM OFFLINE", font=font_lg, fill=0)
        draw.text((20, 65), "It is safe to unplug power in next 10 seconds...", font=font_sm, fill=0)
        draw.text((95, 95), "Z z z . . .", font=font_sm, fill=0)

        epd.display(epd.getbuffer(image))
        epd.sleep()

    except Exception as e:
        print(f"Error drawing shutdown screen: {e}")

if __name__ == "__main__":
    main()
EOF

echo "[4/6] Generating button_toggler.py..."
cat << 'EOF' > $SCRIPT_DIR/button_toggler.py
import subprocess
import time
import os
from gpiozero import Button
from signal import pause

# Define the GPIO pin
BUTTON_PIN = 27

# Setup the button (hold_time=5 for the shutdown feature)
button = Button(BUTTON_PIN, bounce_time=0.3, hold_time=5)

def is_service_active(service_name):
    """Checks if a systemd service is currently running."""
    res = subprocess.run(['systemctl', 'is-active', service_name], capture_output=True, text=True)
    return res.stdout.strip() == 'active'

def toggle_display():
    """Safely swaps the active e-paper service."""
    print("Button pressed! Toggling display...")
    dash_running = is_service_active('epaper_dash.service')
    
    if dash_running:
        subprocess.run(['sudo', 'systemctl', 'stop', 'epaper_dash.service'])
        time.sleep(1) 
        subprocess.run(['sudo', 'systemctl', 'start', 'epaper_console.service'])
    else:
        subprocess.run(['sudo', 'systemctl', 'stop', 'epaper_console.service'])
        time.sleep(1)
        subprocess.run(['sudo', 'systemctl', 'start', 'epaper_dash.service'])

def shutdown_pi():
    """Safely shuts down the Raspberry Pi when button is held."""
    print("Button held for 5 seconds! Shutting down system...")
    
    # Safely stop the e-paper services so the screen doesn't freeze in a weird state
    subprocess.run(['sudo', 'systemctl', 'stop', 'epaper_dash.service'])
    subprocess.run(['sudo', 'systemctl', 'stop', 'epaper_console.service'])
    
    # Brief pause to ensure SPI bus is completely released
    time.sleep(1) 
    
    # Draw the final offline screen
    script_dir = os.path.dirname(os.path.realpath(__file__))
    subprocess.run(['sudo', '/usr/bin/python3', f'{script_dir}/shutdown_screen.py'])
    
    # Send the shutdown command to Linux
    subprocess.run(['sudo', 'shutdown', 'now'])

# Map the hardware actions to the functions
button.when_pressed = toggle_display
button.when_held = shutdown_pi

print(f"Button Controller running on GPIO {BUTTON_PIN}...")
print(" - Press to toggle screens")
print(" - Hold for 5 seconds to shutdown")

# Keep the script running forever
pause()
EOF

echo "[5/6] Creating Systemd Services..."
# 1. Console Service
sudo bash -c "cat << EOF_SERVICE > /etc/systemd/system/epaper_console.service
[Unit]
Description=E-Paper Live Console Service
After=network.target

[Service]
WorkingDirectory=$SCRIPT_DIR
ExecStart=/usr/bin/python3 $SCRIPT_DIR/live_console.py
User=root
StandardOutput=inherit
StandardError=inherit

[Install]
WantedBy=multi-user.target
EOF_SERVICE"

# 2. Button Service
sudo bash -c "cat << EOF_SERVICE > /etc/systemd/system/epaper_button.service
[Unit]
Description=E-Paper Button Toggler
After=network.target

[Service]
ExecStart=/usr/bin/python3 $SCRIPT_DIR/button_toggler.py
User=root
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_SERVICE"

echo "[6/6] Reloading systemd and enabling Button Service..."
sudo systemctl daemon-reload
# We do NOT enable the console service at boot, only the button listener
sudo systemctl enable epaper_button.service
sudo systemctl restart epaper_button.service

echo "=========================================="
echo "  Success! Press your button on GPIO 27   "
echo "  to toggle between the Dashboard & CLI!  "
echo "  Hold for 5 seconds to safely shutdown.  "
echo "=========================================="
