Its simple to deply this web app.

STEP 1: git clone the repository 
STEP 2: cd <cloned repository>
STEP 3: Will be deploy.sh inside, make it executable
STEP 4: chmod +x deploy.sh
STEP 5: bash deploy.sh
STEP 6: wait for the terminal to show:
Run `npm audit` for details.
✅ npm install completed.
✅ Copied kaka.com.pem into backend/
✅ Copied kaka.com-key.pem into backend/
ℹ️  Not running as root → using non-privileged ports HTTP=8080 HTTPS=8443
ℹ️  Patching /home/manzil/demo-repo/run/backend/server.js to use HTTP_PORT/HTTPS_PORT (defaults 8080/8443)...
✅ Patched ports. Backup saved: /home/manzil/demo-repo/run/backend/server.js.bak
ℹ️  Checking/clearing ports...
✅ Port 8080 is free
✅ Port 8443 is free
ℹ️  Starting application...
✅ App started (PID: 30578)
✅ Logs: /home/manzil/demo-repo/run/logs/backend.log

➡️  Try:
   HTTP : http://localhost:8080
   HTTPS: https://localhost:8443

🛑 Stop:
   kill 30578

Deployment Successfull now visit those locally hosted domains.
