#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  NordVPN Setup Script${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Check if nordvpn is installed
if ! command -v nordvpn &> /dev/null; then
    echo -e "${RED}Error: NordVPN is not installed.${NC}"
    echo "Please install it first with:"
    echo "  curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh | sh"
    exit 1
fi

# Check current login status
echo -e "${YELLOW}Checking NordVPN status...${NC}"
if nordvpn account 2>&1 | grep -q "You are not logged in"; then
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

# Login if needed
if [ "$LOGGED_IN" = false ]; then
    echo -e "${YELLOW}Login Options:${NC}"
    echo "  1. Token login (recommended for servers)"
    echo "  2. Browser login (opens browser, then uses callback URL)"
    echo ""
    read -p "Choose login method (1 or 2) [2]: " LOGIN_METHOD
    LOGIN_METHOD=${LOGIN_METHOD:-2}
    
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
nordvpn settings | grep -E "LAN Discovery|Allowlisted"
echo ""
echo -e "${CYAN}Summary:${NC}"
echo -e "  • Local network ($NETWORK): ${GREEN}Accessible${NC} (LAN Discovery)"
echo -e "  • SSH port 22: ${GREEN}Bypasses VPN${NC} (allowlisted)"
if [[ "$ALLOW_EXTERNAL_SSH" =~ ^[Yy] ]]; then
    echo -e "  • External SSH: ${GREEN}Should work${NC} (port 22 allowlisted)"
    echo -e "    ${CYAN}Note: SSH responses will use your home IP, not VPN IP${NC}"
fi
echo ""
echo -e "${BLUE}To connect to VPN:${NC}"
echo "  nordvpn connect"
echo ""
echo -e "${BLUE}To check status:${NC}"
echo "  nordvpn status"
echo ""
echo -e "${BLUE}To disconnect:${NC}"
echo "  nordvpn disconnect"
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
    echo -e "${YELLOW}Fetching available countries...${NC}"
    COUNTRIES=$(nordvpn countries 2>&1)
    
    if [ $? -eq 0 ] && [ -n "$COUNTRIES" ]; then
        echo ""
        echo -e "${CYAN}Available Countries (showing first 50):${NC}"
        TOTAL_COUNTRIES=$(echo "$COUNTRIES" | wc -l)
        DISPLAY_COUNT=50
        
        # Display countries in a readable format
        echo "$COUNTRIES" | head -$DISPLAY_COUNT | while IFS= read -r country; do
            # Format country names (replace underscores with spaces, capitalize words)
            formatted=$(echo "$country" | sed 's/_/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2));}1')
            printf "  %-40s %s\n" "$formatted" "($country)"
        done
        
        if [ $TOTAL_COUNTRIES -gt $DISPLAY_COUNT ]; then
            echo ""
            echo -e "${YELLOW}  ... and $((TOTAL_COUNTRIES - DISPLAY_COUNT)) more countries${NC}"
            echo -e "${CYAN}  (Use the exact format shown in parentheses)${NC}"
        fi
        
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
            
            echo ""
            echo -e "${YELLOW}Connection Status:${NC}"
            nordvpn status
        fi
    else
        echo -e "${YELLOW}Could not fetch countries list. Connecting to fastest server...${NC}"
        if nordvpn connect; then
            echo -e "${GREEN}✓ Connected successfully!${NC}"
        else
            echo -e "${RED}✗ Connection failed${NC}"
        fi
    fi
else
    echo ""
    echo -e "${CYAN}You can connect later with:${NC}"
    echo "  nordvpn connect                    # Fastest server"
    echo "  nordvpn connect United_States      # Specific country"
    echo "  nordvpn countries                  # List all countries"
fi
echo ""

