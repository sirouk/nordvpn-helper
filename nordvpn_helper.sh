#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Run the NordVPN installer from an absolute temporary path so this helper works
# no matter which directory it is launched from.
run_nordvpn_installer() {
    local installer_path

    installer_path=$(mktemp "${TMPDIR:-/tmp}/nordvpn-install.XXXXXX.sh")
    if ! wget -q https://downloads.nordcdn.com/apps/linux/install.sh -O "$installer_path"; then
        echo -e "${RED}Error: Failed to download the NordVPN installer.${NC}"
        rm -f "$installer_path"
        return 1
    fi

    if ! bash "$installer_path"; then
        echo -e "${RED}Error: NordVPN installer failed.${NC}"
        rm -f "$installer_path"
        return 1
    fi

    rm -f "$installer_path"
}

# Add a subnet to NordVPN allowlist (idempotent-ish with friendly output)
add_allowlist_subnet() {
    local subnet="$1"
    local label="$2"
    local out
    local code

    out=$(nordvpn allowlist add subnet "$subnet" 2>&1) || true
    code=$?
    if [ $code -eq 0 ] || echo "$out" | grep -qi "already allowlisted\|already"; then
        if echo "$out" | grep -qi "already"; then
            echo -e "${GREEN}✓ $label $subnet already allowlisted${NC}"
        else
            echo -e "${GREEN}✓ $label $subnet added to allowlist${NC}"
        fi
    elif echo "$out" | grep -qi "not available while local network discovery is enabled"; then
        echo -e "${YELLOW}ℹ Could not add $label $subnet while LAN Discovery is enabled${NC}"
    else
        echo -e "${YELLOW}ℹ Could not add $label $subnet${NC}"
        echo "Output: $out"
    fi
}

# Add a port to NordVPN allowlist (idempotent-ish with friendly output)
add_allowlist_port() {
    local port="$1"
    local label="$2"
    local out
    local code

    out=$(nordvpn allowlist add port "$port" 2>&1) || true
    code=$?
    if [ $code -eq 0 ] || echo "$out" | grep -qi "already allowlisted\|already"; then
        if echo "$out" | grep -qi "already"; then
            echo -e "${GREEN}✓ $label port $port already allowlisted${NC}"
        else
            echo -e "${GREEN}✓ $label port $port added to allowlist${NC}"
        fi
    else
        echo -e "${YELLOW}ℹ Could not add $label port $port${NC}"
        echo "Output: $out"
    fi
}

# Fetch public IPv4 from a fallback list of services.
fetch_public_ipv4() {
    local ip=""
    ip=$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null || true)
    if [ -z "$ip" ]; then
        ip=$(curl -4 -s --max-time 10 https://ifconfig.me/ip 2>/dev/null || true)
    fi
    echo "$ip"
}

# Print status and optional dedicated-IP match check.
print_connection_verification() {
    local expected_ip="$1"
    local public_ip=""

    echo ""
    echo -e "${YELLOW}Connection Status:${NC}"
    nordvpn status || true

    public_ip=$(fetch_public_ipv4)
    if [ -n "$public_ip" ]; then
        echo -e "Public IPv4: ${GREEN}${public_ip}${NC}"
        if [ -n "$expected_ip" ]; then
            if [ "$public_ip" = "$expected_ip" ]; then
                echo -e "${GREEN}✓ Dedicated IP confirmed (${expected_ip})${NC}"
            else
                echo -e "${YELLOW}⚠ Expected dedicated IP ${expected_ip}, but got ${public_ip}${NC}"
                echo -e "${YELLOW}  The server is correct but NordVPN is using a shared pool IP instead.${NC}"
                echo -e "${CYAN}  Steps to fix:${NC}"
                echo -e "    1. Update NordVPN: sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)"
                echo -e "    2. Re-login to refresh the dedicated IP token:"
                echo -e "       nordvpn disconnect && nordvpn logout && nordvpn login --token <token>"
                echo -e "    3. Reconnect: nordvpn connect --group Dedicated_IP"
            fi
        fi
    else
        echo -e "${YELLOW}Could not fetch public IPv4 (curl failed).${NC}"
    fi
}


echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  NordVPN Setup Script${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Check if nordvpn is installed
if ! command -v nordvpn &> /dev/null; then
    echo -e "${RED}Error: NordVPN is not installed. Installing...${NC}"
    run_nordvpn_installer
fi

# Check for NordVPN update by comparing installed vs latest available in apt,
# with a fallback to the NordVPN CLI's own update nag in case apt metadata is stale.
echo -e "${YELLOW}Checking NordVPN version...${NC}"
APT_POLICY=$(apt-cache policy nordvpn 2>/dev/null || true)
APT_INSTALLED=$(echo "$APT_POLICY" | awk '/Installed:/{print $2}' | head -1 || true)
APT_CANDIDATE=$(echo "$APT_POLICY" | awk '/Candidate:/{print $2}' | head -1 || true)
INSTALLED_VER=$(nordvpn --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ -z "$INSTALLED_VER" ] && [ -n "$APT_INSTALLED" ] && [ "$APT_INSTALLED" != "(none)" ]; then
    INSTALLED_VER=$(echo "$APT_INSTALLED" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
fi
LATEST_VER=$(echo "$APT_CANDIDATE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
UPDATE_AVAILABLE=false

if [ -n "$INSTALLED_VER" ]; then
    echo -e "  Installed: ${CYAN}${INSTALLED_VER}${NC}"
fi

if [ -n "$APT_CANDIDATE" ] && [ "$APT_CANDIDATE" != "(none)" ] && \
   [ -n "$APT_INSTALLED" ] && [ "$APT_INSTALLED" != "(none)" ] && \
   command -v dpkg &> /dev/null && dpkg --compare-versions "$APT_CANDIDATE" gt "$APT_INSTALLED"; then
    UPDATE_AVAILABLE=true
    echo -e "  Latest:    ${GREEN}${LATEST_VER}${NC}"
fi

_nag=$(nordvpn status 2>&1 || true)
if echo "$_nag" | grep -qi "new version\|please update"; then
    if [ "$UPDATE_AVAILABLE" = false ] && [ -z "$LATEST_VER" ]; then
        echo -e "  ${YELLOW}(latest version unknown, but NordVPN reports an update is available)${NC}"
    elif [ "$UPDATE_AVAILABLE" = false ] && [ -n "$LATEST_VER" ] && [ "$LATEST_VER" = "$INSTALLED_VER" ]; then
        echo -e "  ${YELLOW}(NordVPN reports an update, but local apt metadata still shows ${LATEST_VER}; apt cache may be stale)${NC}"
    fi
    UPDATE_AVAILABLE=true
elif [ -n "$INSTALLED_VER" ] && [ -z "$LATEST_VER" ]; then
    echo -e "  ${GREEN}(latest version unknown, no update nag detected)${NC}"
elif [ -z "$INSTALLED_VER" ] && [ -z "$LATEST_VER" ]; then
    echo -e "  ${YELLOW}(could not determine the installed version or latest candidate)${NC}"
fi

if [ "$UPDATE_AVAILABLE" = true ]; then
    echo ""
    echo -e "${YELLOW}⚠ A newer version of NordVPN is available.${NC}"
    echo -e "  ${RED}Outdated versions are known to break Dedicated IP routing.${NC}"
    echo -e "  ${CYAN}Press Y to update now (recommended), or N to skip.${NC}"
    echo ""
    read -p "Update NordVPN now? (y/n) [y]: " DO_UPDATE
    DO_UPDATE=${DO_UPDATE:-y}
    if [[ "$DO_UPDATE" =~ ^[Yy] ]]; then
        echo ""
        echo -e "${YELLOW}Updating NordVPN...${NC}"
        if sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh); then
            NEW_VER=$(nordvpn --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
            echo -e "${GREEN}✓ NordVPN updated to ${NEW_VER}.${NC}"
            echo -e "${YELLOW}⚠ You will need to re-login — the update invalidates the existing session.${NC}"
            LOGGED_IN=false
        else
            echo -e "${RED}✗ Update failed. Continuing with current version.${NC}"
        fi
    else
        echo -e "${YELLOW}Skipping update. Dedicated IP may not work correctly on ${INSTALLED_VER}.${NC}"
    fi
    echo ""
else
    if [ -n "$LATEST_VER" ] && [ "$LATEST_VER" = "$INSTALLED_VER" ]; then
        echo -e "${GREEN}✓ NordVPN ${INSTALLED_VER} is up to date.${NC}"
    elif [ -n "$INSTALLED_VER" ]; then
        echo -e "${GREEN}✓ No update detected for NordVPN ${INSTALLED_VER}.${NC}"
    else
        echo -e "${GREEN}✓ No update detected.${NC}"
    fi
fi

# Check current login status (skip re-check if update already forced a re-login)
echo -e "${YELLOW}Checking NordVPN login status...${NC}"
if [ "${LOGGED_IN:-}" = "false" ]; then
    echo -e "${YELLOW}Re-login required after update.${NC}"
elif nordvpn account 2>&1 | grep -iq "not logged in"; then
    echo -e "${YELLOW}Not logged in. Proceeding with login...${NC}"
    LOGGED_IN=false
else
    echo -e "${GREEN}Already logged in.${NC}"
    LOGGED_IN=true
fi

# Detect local subnet
echo ""
echo -e "${YELLOW}Detecting local network configuration...${NC}"
CIDR=$(ip addr show | grep -E "inet.*scope global" | awk '{print $2}' | head -1)
LOCAL_IP=$(echo "$CIDR" | cut -d'/' -f1)
LOCAL_SUBNET=$(echo "$CIDR" | cut -d'/' -f2)

# Calculate network address
if command -v ipcalc &> /dev/null; then
    NETWORK=$(ipcalc -n "$CIDR" 2>/dev/null | cut -d'=' -f2)
else
    # Fallback: simple calculation for common subnets
    IFS='.' read -r i1 i2 i3 i4 <<< "$LOCAL_IP"
    case $LOCAL_SUBNET in
        24) NETWORK="$i1.$i2.$i3.0/24" ;;
        16) NETWORK="$i1.$i2.0.0/16" ;;
        8)  NETWORK="$i1.0.0.0/8" ;;
        *)  NETWORK="$i1.$i2.$i3.0/$LOCAL_SUBNET" ;;
    esac
fi

echo -e "  Local IP: ${GREEN}$LOCAL_IP${NC}"
echo -e "  Network: ${GREEN}$NETWORK${NC}"
echo ""

# Detect Tailscale (if installed)
TAILSCALE_AVAILABLE=false
TAILSCALE_UP=false
TAILSCALE_IPV4_LIST=""
TAILSCALE_IPV6_LIST=""
TAILSCALE_ALL_IPS=""

if command -v tailscale &> /dev/null; then
    TAILSCALE_AVAILABLE=true
    TAILSCALE_IPV4_LIST=$(tailscale ip -4 2>/dev/null || true)
    TAILSCALE_IPV6_LIST=$(tailscale ip -6 2>/dev/null || true)
    if [ -n "$TAILSCALE_IPV4_LIST" ] || [ -n "$TAILSCALE_IPV6_LIST" ]; then
        TAILSCALE_UP=true
        if tailscale status --json >/tmp/ts_status.json 2>/dev/null; then
            TAILSCALE_ALL_IPS=$(python3 - <<'PY' 2>/dev/null || true
import json
from ipaddress import ip_address

with open("/tmp/ts_status.json", "r", encoding="utf-8") as f:
    data = json.load(f)

ips = set()
self_node = data.get("Self") or {}
for ip in self_node.get("TailscaleIPs") or []:
    ips.add(ip)
for peer in (data.get("Peer") or {}).values():
    for ip in (peer.get("TailscaleIPs") or []):
        ips.add(ip)

for ip in sorted(ips, key=lambda s: (ip_address(s).version, int(ip_address(s)))):
    print(ip)
PY
)
        fi
        if [ -z "$TAILSCALE_ALL_IPS" ]; then
            TAILSCALE_ALL_IPS="$TAILSCALE_IPV4_LIST"$'\n'"$TAILSCALE_IPV6_LIST"
        fi
    fi
fi

# Login if needed
if [ "$LOGGED_IN" = false ]; then
    echo -e "${YELLOW}Login Options:${NC}"
    echo "  1. Token login (recommended for servers — fast and reliable)"
    echo "  2. Browser login (callback URL — can fail on headless/remote machines)"
    echo ""
    echo -e "${CYAN}  Token: https://my.nordaccount.com/dashboard/nordvpn/service-credentials/${NC}"
    echo ""
    read -p "Choose login method (1 or 2) [1]: " LOGIN_METHOD
    LOGIN_METHOD=${LOGIN_METHOD:-1}
    
    case $LOGIN_METHOD in
        1)
            echo ""
            echo -e "${YELLOW}Token Login:${NC}"
            echo "Generate a token at: https://my.nordaccount.com/dashboard/nordvpn/service-credentials/"
            echo ""
            read -p "Enter your NordVPN token: " TOKEN
            if [ -z "$TOKEN" ]; then
                echo -e "${RED}Error: Token cannot be empty.${NC}"
                exit 1
            fi
            echo ""
            echo -e "${YELLOW}Logging in with token...${NC}"
            if nordvpn login --token "$TOKEN"; then
                echo -e "${GREEN}✓ Login successful!${NC}"
            else
                echo -e "${RED}✗ Login failed. Please check your token.${NC}"
                exit 1
            fi
            ;;
        2)
            echo ""
            echo -e "${YELLOW}Browser Login:${NC}"
            echo "Starting NordVPN login process..."
            echo ""
            
            # Run nordvpn login to get the URL
            LOGIN_OUTPUT=$(nordvpn login 2>&1)
            # Extract URL (handles both "Continue in the browser: URL" and just "URL" formats)
            LOGIN_URL=$(echo "$LOGIN_OUTPUT" | grep -oE 'https://[^[:space:]]+' | head -1)
            
            if [ -z "$LOGIN_URL" ]; then
                echo -e "${RED}✗ Failed to get login URL from NordVPN${NC}"
                echo "Output: $LOGIN_OUTPUT"
                exit 1
            fi
            
            echo -e "${CYAN}Login URL:${NC}"
            echo -e "${BLUE}$LOGIN_URL${NC}"
            echo ""
            echo -e "${YELLOW}Instructions:${NC}"
            echo "1. Open the URL above in your browser"
            echo "2. Log in to your Nord Account"
            echo "3. After logging in, you'll be redirected to a 'Continue' page"
            echo "4. Right-click the 'Continue' button and copy the link address"
            echo ""
            while true; do
                read -p "Paste the callback URL here: " CALLBACK_URL
                if [ -n "$CALLBACK_URL" ]; then
                    break
                fi
                echo -e "${RED}Error: Callback URL cannot be empty.${NC}"
            done
            
            echo ""
            echo -e "${YELLOW}Completing login with callback URL...${NC}"
            if nordvpn login --callback "$CALLBACK_URL"; then
                echo -e "${GREEN}✓ Login successful!${NC}"
            else
                echo -e "${RED}✗ Login failed. Please check your callback URL.${NC}"
                echo -e "${YELLOW}Make sure you copied the full URL from the 'Continue' button.${NC}"
                exit 1
            fi
            ;;
        *)
            echo -e "${RED}Invalid choice. Exiting.${NC}"
            exit 1
            ;;
    esac
fi

# Configure LAN Discovery
echo ""
echo -e "${YELLOW}Configuring LAN Discovery...${NC}"
LAN_DISC_OUTPUT=$(nordvpn set lan-discovery on 2>&1) || true
LAN_DISC_EXIT=$?

if [ $LAN_DISC_EXIT -eq 0 ] || echo "$LAN_DISC_OUTPUT" | grep -q "already set to enabled"; then
    if echo "$LAN_DISC_OUTPUT" | grep -q "already"; then
        echo -e "${GREEN}✓ LAN Discovery already enabled${NC}"
    else
        echo -e "${GREEN}✓ LAN Discovery enabled${NC}"
    fi
    echo -e "  ${CYAN}This allows local network access (192.168.x.x)${NC}"
else
    echo -e "${RED}✗ Failed to enable LAN Discovery${NC}"
    echo "Output: $LAN_DISC_OUTPUT"
    exit 1
fi

# Configure Firewall (Crucial for WSL)
echo ""
echo -e "${YELLOW}Configuring NordVPN Firewall (Disabling for WSL compatibility)...${NC}"
FIREWALL_OUTPUT=$(nordvpn set firewall disabled 2>&1) || true
if echo "$FIREWALL_OUTPUT" | grep -qE "successfully|already"; then
    echo -e "${GREEN}✓ Firewall disabled${NC}"
else
    echo -e "${RED}✗ Failed to disable firewall${NC}"
    echo "Output: $FIREWALL_OUTPUT"
fi

# Configure Technology (NordLynx is recommended for performance)
echo ""
echo -e "${YELLOW}Configuring Technology (Setting to NordLynx)...${NC}"
TECH_OUTPUT=$(nordvpn set technology nordlynx 2>&1) || true
if echo "$TECH_OUTPUT" | grep -qE "successfully|already"; then
    echo -e "${GREEN}✓ Technology set to NordLynx${NC}"
else
    echo -e "${RED}✗ Failed to set technology to NordLynx${NC}"
    echo "Output: $TECH_OUTPUT"
fi

# Configure Tailscale coexistence with NordVPN
if [ "$TAILSCALE_AVAILABLE" = true ]; then
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Tailscale Coexistence Configuration${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    if [ "$TAILSCALE_UP" = true ]; then
        echo -e "${GREEN}✓ Tailscale detected and active${NC}"
        if [ -n "$TAILSCALE_IPV4_LIST" ]; then
            echo -e "  Local Tailscale IPv4: ${GREEN}$(echo "$TAILSCALE_IPV4_LIST" | tr '\n' ' ')${NC}"
        fi
        if [ -n "$TAILSCALE_IPV6_LIST" ]; then
            echo -e "  Local Tailscale IPv6: ${GREEN}$(echo "$TAILSCALE_IPV6_LIST" | tr '\n' ' ')${NC}"
        fi
        echo ""
        echo -e "${YELLOW}Enable NordVPN+Tailscale coexistence mode?${NC}"
        echo -e "  This adds Tailscale traffic to NordVPN allowlist so your tailnet can still reach this node."
        read -p "Enable coexistence mode? (y/n) [y]: " ENABLE_TS_COEXIST
        ENABLE_TS_COEXIST=${ENABLE_TS_COEXIST:-y}

        if [[ "$ENABLE_TS_COEXIST" =~ ^[Yy] ]]; then
            echo ""
            echo -e "${YELLOW}Choose allowlist scope:${NC}"
            echo "  1. Broad (recommended): allow Tailscale CGNAT + ULA ranges"
            echo "     - 100.64.0.0/10"
            echo "     - fd7a:115c:a1e0::/48"
            echo "  2. Precise: allow only currently detected Tailscale node IPs"
            read -p "Select option (1 or 2) [1]: " TS_SCOPE
            TS_SCOPE=${TS_SCOPE:-1}

            echo ""
            echo -e "${YELLOW}Applying Tailscale allowlist rules...${NC}"
            if [ "$TS_SCOPE" = "2" ]; then
                if [ -z "$TAILSCALE_ALL_IPS" ]; then
                    echo -e "${YELLOW}ℹ Could not read Tailscale peer IPs; falling back to broad mode.${NC}"
                    add_allowlist_subnet "100.64.0.0/10" "Tailscale IPv4 range"
                    add_allowlist_subnet "fd7a:115c:a1e0::/48" "Tailscale IPv6 range"
                else
                    while IFS= read -r ts_ip; do
                        [ -z "$ts_ip" ] && continue
                        if [[ "$ts_ip" == *:* ]]; then
                            add_allowlist_subnet "$ts_ip/128" "Tailscale node"
                        else
                            add_allowlist_subnet "$ts_ip/32" "Tailscale node"
                        fi
                    done <<< "$TAILSCALE_ALL_IPS"
                fi
            else
                add_allowlist_subnet "100.64.0.0/10" "Tailscale IPv4 range"
                add_allowlist_subnet "fd7a:115c:a1e0::/48" "Tailscale IPv6 range"
            fi

            echo ""
            echo -e "${YELLOW}Optional: allowlist Tailscale coordination port (UDP 41641)${NC}"
            read -p "Add UDP 41641 to allowlist? (y/n) [y]: " TS_PORT_ALLOW
            TS_PORT_ALLOW=${TS_PORT_ALLOW:-y}
            if [[ "$TS_PORT_ALLOW" =~ ^[Yy] ]]; then
                add_allowlist_port "41641" "Tailscale"
            fi
        else
            echo -e "${YELLOW}Skipping Tailscale coexistence configuration.${NC}"
        fi
    else
        echo -e "${YELLOW}ℹ Tailscale installed but not active (no Tailscale IP assigned).${NC}"
        echo -e "  Start it first with: ${CYAN}tailscale up${NC}"
    fi
fi

# Ask about external SSH access (port forwarding scenario)
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  External SSH Access Configuration${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Do you connect to this machine via port forwarding from work?${NC}"
echo -e "  (e.g., router forwards external port → this machine)"
echo ""
read -p "Allow external SSH access? (y/n) [y]: " ALLOW_EXTERNAL_SSH
ALLOW_EXTERNAL_SSH=${ALLOW_EXTERNAL_SSH:-y}

if [[ "$ALLOW_EXTERNAL_SSH" =~ ^[Yy] ]]; then
    echo ""
    echo -e "${YELLOW}To ensure SSH works from external IPs:${NC}"
    echo "  1. SSH port (22) will be allowlisted (bypasses VPN)"
    echo "  2. Optionally add your work IP/subnet to allowlist"
    echo ""
    read -p "Add your work IP or subnet to allowlist? (y/n) [y]: " ADD_WORK_IP
    ADD_WORK_IP=${ADD_WORK_IP:-y}
    
    if [[ "$ADD_WORK_IP" =~ ^[Yy] ]]; then
        echo ""
        echo -e "${YELLOW}Enter your work IP or subnet:${NC}"
        echo "  Examples:"
        echo "    - Single IP: 203.0.113.45"
        echo "    - Subnet: 203.0.113.0/24"
        echo ""
        read -p "Work IP/subnet: " WORK_IP
        
        if [ -n "$WORK_IP" ]; then
            # Validate format (basic check)
            if [[ "$WORK_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
                # Add /32 if single IP provided
                if [[ ! "$WORK_IP" =~ / ]]; then
                    WORK_IP="$WORK_IP/32"
                fi
                
                echo ""
                echo -e "${YELLOW}Adding work IP/subnet to allowlist...${NC}"
                WORK_IP_OUTPUT=$(nordvpn allowlist add subnet "$WORK_IP" 2>&1) || true
                WORK_IP_EXIT=$?
                
                if [ $WORK_IP_EXIT -eq 0 ] || echo "$WORK_IP_OUTPUT" | grep -q "successfully\|already allowlisted"; then
                    if echo "$WORK_IP_OUTPUT" | grep -q "already"; then
                        echo -e "${GREEN}✓ Work IP/subnet $WORK_IP already allowlisted${NC}"
                    else
                        echo -e "${GREEN}✓ Work IP/subnet $WORK_IP added to allowlist${NC}"
                    fi
                elif echo "$WORK_IP_OUTPUT" | grep -q "not available while local network discovery is enabled"; then
                    echo -e "${YELLOW}ℹ Cannot add subnet while LAN Discovery is enabled${NC}"
                    echo -e "${CYAN}  LAN Discovery handles local networks automatically${NC}"
                    echo -e "${CYAN}  For external IPs, SSH port allowlisting should be sufficient${NC}"
                else
                    echo -e "${YELLOW}ℹ Could not add subnet${NC}"
                    echo "Output: $WORK_IP_OUTPUT"
                fi
            else
                echo -e "${RED}Invalid IP/subnet format. Skipping.${NC}"
            fi
        fi
    fi
fi

# Allowlist SSH port (critical for external access)
echo ""
echo -e "${YELLOW}Configuring SSH port allowlist...${NC}"
SSH_PORT_OUTPUT=$(nordvpn allowlist add port 22 2>&1) || true
SSH_PORT_EXIT=$?

if [ $SSH_PORT_EXIT -eq 0 ] || echo "$SSH_PORT_OUTPUT" | grep -q "already allowlisted"; then
    if echo "$SSH_PORT_OUTPUT" | grep -q "already"; then
        echo -e "${GREEN}✓ SSH port 22 already allowlisted${NC}"
    else
        echo -e "${GREEN}✓ SSH port 22 added to allowlist${NC}"
    fi
    echo -e "  ${CYAN}SSH traffic will bypass VPN (works for local and external connections)${NC}"
else
    # Check if already allowlisted via settings
    if nordvpn settings 2>&1 | grep -q "22.*UDP\|TCP"; then
        echo -e "${GREEN}✓ SSH port 22 already allowlisted${NC}"
    else
        echo -e "${YELLOW}ℹ Could not add SSH port (check manually with 'nordvpn settings')${NC}"
        echo "Output: $SSH_PORT_OUTPUT"
    fi
fi

# Show final configuration
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Configuration Complete!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Current NordVPN Settings:${NC}"
nordvpn settings | grep -E "LAN Discovery|Allowlisted|Firewall|Technology"
echo ""
echo -e "${CYAN}Summary:${NC}"
echo -e "  • Local network ($NETWORK): ${GREEN}Accessible${NC} (LAN Discovery)"
echo -e "  • Firewall: ${GREEN}Disabled${NC} (WSL Compatibility)"
echo -e "  • Technology: ${GREEN}NordLynx${NC} (Performance)"
echo -e "  • SSH port 22: ${GREEN}Bypasses VPN${NC} (allowlisted)"
if [[ "$ALLOW_EXTERNAL_SSH" =~ ^[Yy] ]]; then
    echo -e "  • External SSH: ${GREEN}Should work${NC} (port 22 allowlisted)"
    echo -e "    ${CYAN}Note: SSH responses will use your home IP, not VPN IP${NC}"
fi
echo ""
echo -e "${BLUE}To connect to VPN:${NC}"
echo "  nordvpn connect                                     # Fastest server"
echo "  nordvpn connect Ireland                             # Specific country"
echo "  nordvpn connect --group Dedicated_IP                # Your dedicated IP"
echo "  nordvpn connect --group Dedicated_IP Ireland        # Dedicated IP in a country"
echo ""
echo -e "${BLUE}To check status:${NC}"
echo "  nordvpn status"
echo "  curl -4 -s https://api.ipify.org    # Check public IPv4"
echo ""
echo -e "${BLUE}To disconnect:${NC}"
echo "  nordvpn disconnect"
echo "  nordvpn set autoconnect on <server_id>  # Pin auto-connect to a specific server"
echo ""
echo -e "${YELLOW}Important Notes:${NC}"
echo -e "  • SSH port 22 is allowlisted, so SSH traffic bypasses VPN"
echo -e "  • This means SSH connections (local and external) will work"
echo -e "  • Your SSH server IP will be your home IP, not the VPN IP"
echo -e "  • Other internet traffic will route through VPN"
echo ""

# Ask if user wants to connect now
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Connect to VPN${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
read -p "Connect to VPN now? (y/n) [y]: " CONNECT_NOW
CONNECT_NOW=${CONNECT_NOW:-y}

if [[ "$CONNECT_NOW" =~ ^[Yy] ]]; then
    echo ""
    echo -e "${YELLOW}Choose connection mode:${NC}"
    echo "  1. Fastest server"
    echo "  2. Specific country (default flow)"
    echo "  3. Dedicated IP (account-assigned, uses --group Dedicated_IP)"
    echo ""
    read -p "Mode (1/2/3) [2]: " CONNECT_MODE
    CONNECT_MODE=${CONNECT_MODE:-2}

    if [ "$CONNECT_MODE" = "1" ]; then
        echo ""
        echo -e "${YELLOW}Connecting to fastest server...${NC}"
        if nordvpn connect; then
            echo -e "${GREEN}✓ Connected successfully!${NC}"
            print_connection_verification ""
        else
            echo -e "${RED}✗ Connection failed${NC}"
        fi
    elif [ "$CONNECT_MODE" = "3" ]; then
        echo ""
        echo -e "${YELLOW}Dedicated IP mode${NC}"
        echo -e "${CYAN}Connects via your account's assigned dedicated IP using --group Dedicated_IP.${NC}"
        echo -e "${CYAN}Do NOT use a server id (e.g. ie214) — that gives a shared pool IP, not your dedicated IP.${NC}"
        echo ""
        read -p "Country for dedicated IP (optional, e.g. Ireland) [Ireland]: " DEDICATED_COUNTRY
        DEDICATED_COUNTRY=${DEDICATED_COUNTRY:-Ireland}

        read -p "Expected dedicated public IPv4 (optional): " EXPECTED_DEDICATED_IP

        echo ""
        echo -e "${YELLOW}Connecting to dedicated IP${DEDICATED_COUNTRY:+ in ${DEDICATED_COUNTRY}}...${NC}"
        if nordvpn connect --group Dedicated_IP ${DEDICATED_COUNTRY:+"$DEDICATED_COUNTRY"}; then
            echo -e "${GREEN}✓ Connected via dedicated IP successfully!${NC}"
            print_connection_verification "${EXPECTED_DEDICATED_IP}"
            echo ""
            echo -e "${CYAN}Optional: persist this on reboot:${NC}"
            echo "  nordvpn set autoconnect on --group Dedicated_IP${DEDICATED_COUNTRY:+ ${DEDICATED_COUNTRY}}"
        else
            echo -e "${RED}✗ Connection failed${NC}"
            echo -e "${YELLOW}Make sure Dedicated IP service is active in your Nord Account:${NC}"
            echo -e "  https://my.nordaccount.com/dashboard/nordvpn/dedicated-ip/"
            echo -e "${YELLOW}Try manually: nordvpn connect --group Dedicated_IP${NC}"
        fi
    else
        echo ""
        echo -e "${YELLOW}Fetching available countries...${NC}"
        COUNTRIES=$(nordvpn countries 2>&1)

        if [ $? -eq 0 ] && [ -n "$COUNTRIES" ]; then
            mapfile -t COUNTRY_ARRAY < <(echo "$COUNTRIES" | awk '{for (i=1; i<=NF; ++i) print $i}')
            TOTAL_COUNTRIES=${#COUNTRY_ARRAY[@]}
            echo ""
            echo -e "${CYAN}Available Countries (${TOTAL_COUNTRIES} total):${NC}"

            for ((idx=0; idx<TOTAL_COUNTRIES; idx++)); do
                country="${COUNTRY_ARRAY[$idx]}"
                formatted=$(echo "$country" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')
                printf "  %2d. %-32s (%s)\n" $((idx + 1)) "$formatted" "$country"
            done
            echo ""
            echo -e "${CYAN}  (Use the exact format shown in parentheses)${NC}"

            echo ""
            echo -e "${YELLOW}Enter country name [Ireland] (type 'fastest' for fastest server):${NC}"
            echo -e "${CYAN}Examples: United_States, United_Kingdom, Netherlands, Japan${NC}"
            echo -e "${CYAN}Note: Use underscores for multi-word countries (e.g., United_States)${NC}"
            echo ""
            read -p "Country: " SELECTED_COUNTRY

            if [ -z "$SELECTED_COUNTRY" ]; then
                SELECTED_COUNTRY="Ireland"
                echo ""
                echo -e "${YELLOW}Defaulting to Ireland...${NC}"
            fi

            if [[ "${SELECTED_COUNTRY,,}" == "fastest" ]]; then
                echo ""
                echo -e "${YELLOW}Connecting to fastest server...${NC}"
                if nordvpn connect; then
                    echo -e "${GREEN}✓ Connected successfully!${NC}"
                    print_connection_verification ""
                else
                    echo -e "${RED}✗ Connection failed${NC}"
                fi
            else
                # Normalize input: convert spaces to underscores, capitalize first letter of each word
                NORMALIZED=$(echo "$SELECTED_COUNTRY" | sed 's/ /_/g' | sed 's/\b\(.\)/\u\1/g')

                echo ""
                echo -e "${YELLOW}Connecting to $NORMALIZED...${NC}"
                if nordvpn connect "$NORMALIZED"; then
                    echo -e "${GREEN}✓ Connected to $NORMALIZED successfully!${NC}"
                else
                    echo -e "${RED}✗ Connection failed${NC}"
                    echo -e "${YELLOW}Trying with original input: $SELECTED_COUNTRY${NC}"
                    if nordvpn connect "$SELECTED_COUNTRY"; then
                        echo -e "${GREEN}✓ Connected successfully!${NC}"
                    else
                        echo -e "${RED}✗ Connection failed. Please check the country name.${NC}"
                        echo -e "${YELLOW}Use 'nordvpn countries' to see the exact format.${NC}"
                    fi
                fi

                print_connection_verification ""
            fi
        else
            echo -e "${YELLOW}Could not fetch countries list. Connecting to fastest server...${NC}"
            if nordvpn connect; then
                echo -e "${GREEN}✓ Connected successfully!${NC}"
                print_connection_verification ""
            else
                echo -e "${RED}✗ Connection failed${NC}"
            fi
        fi
    fi
else
    echo ""
    echo -e "${CYAN}You can connect later with:${NC}"
    echo "  nordvpn connect                                     # Fastest server"
    echo "  nordvpn connect Ireland                             # Specific country"
    echo "  nordvpn connect --group Dedicated_IP                # Your dedicated IP"
    echo "  nordvpn connect --group Dedicated_IP Ireland        # Dedicated IP in a country"
    echo "  nordvpn set autoconnect on --group Dedicated_IP     # Persist dedicated IP on reboot"
    echo "  nordvpn countries                                   # List all countries"
fi
echo ""
