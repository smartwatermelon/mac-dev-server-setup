# Apple First-Boot Dialog Guide

This guide provides step-by-step instructions for navigating Apple's Setup Assistant dialogs during initial Mac Mini configuration.

## Admin Account Setup (Initial macOS Installation)

When setting up the Mac Mini for the first time, you'll encounter these Apple dialogs in sequence:

### 1. Language Selection

- **Action**: Select your preferred language
- **Recommendation**: Choose your primary language

### 2. Region Selection

- **Action**: Select your country/region
- **Recommendation**: Choose your current location for proper timezone and regional settings

### 3. Data Transfer & Migration

- **Action**: Choose transfer method
- **Options**:
  - **iPhone/iPad Transfer** Recommended if available (requires iOS device with backup)
  - **Time Machine Backup** (if you have an existing backup)
  - **Don't transfer any information now** (manual setup)
- **Note**: iPhone/iPad transfer can pre-configure WiFi, Apple ID, and other settings

### 4. Accessibility

- **Action**: Configure accessibility options
- **Recommendation**: Configure as needed for your requirements, or skip if not needed

### 5. Data & Privacy

- **Action**: Review Apple's privacy policy
- **Recommendation**: Continue after reading

### 6. Create Administrator Account

- **Full Name**: Will be pre-populated if you used iPhone/iPad transfer
- **Account Name**: Will be pre-populated if you used iPhone/iPad transfer
- **Password**: Create a strong password (you'll use this for first-boot setup)
- **Hint**: Optional password hint

### 7. Apple Account Configuration

#### 7.1 Terms & Conditions

- **Action**: Agree to Apple's Terms and Conditions
- **Recommendation**: Review and agree

#### 7.2 Customize Settings

##### 7.2.1 Location Services

- **Action**: Enable or disable location services
- **Recommendation**: Enable for timezone and system functionality

##### 7.2.2 Analytics & Improvement

- **Action**: Choose whether to share analytics with Apple
- **Recommendation**: Configure based on your privacy preferences

##### 7.2.3 Screen Time

- **Action**: Set up Screen Time monitoring
- **Recommendation**: Skip for server setup

##### 7.2.4 Apple Intelligence

- **Action**: Configure Apple's AI features
- **Recommendation**: Configure based on your preferences

##### 7.2.5 FileVault Disk Encryption

- **Action**: Choose whether to enable FileVault
- **Recommendation**: Configure based on your security preferences

##### 7.2.6 Touch ID

- **Action**: Set up Touch ID fingerprint authentication
- **Recommendation**: Set up for convenient sudo access during administration

##### 7.2.7 Apple Pay

- **Action**: Set up Apple Pay
- **Recommendation**: Configure based on your preferences

##### 7.2.8 Choose Your Look

- **Action**: Select Light, Dark, or Auto appearance
- **Recommendation**: Auto (adapts to time of day)

##### 7.2.9 Software Updates

- **Action**: Configure automatic update preferences
- **Recommendation**: Enable automatic security updates, manual for system updates

### 8. Continue Setup

- **Action**: Complete the setup process
- **Result**: Proceed to desktop

### 9. Desktop

- **Result**: macOS setup complete, ready for first-boot script execution

---

## Important Notes

### Account Purpose

- **Admin Account**: Used for system administration, setup, maintenance, and day-to-day development work

### Setup Timing

- Complete Apple dialogs **before** running `first-boot.sh`

### Migration Assistant Benefits

Using iPhone/iPad transfer during initial setup can significantly reduce manual configuration by pre-populating:

- WiFi network settings
- Apple ID information
- Basic user account details
- System preferences

This reduces the overall setup time and ensures consistent configuration across your devices.
