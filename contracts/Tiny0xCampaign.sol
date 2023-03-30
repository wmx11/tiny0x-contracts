// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Tiny0xCampaign is AccessControl {
    struct Provider {
        uint256 number;
        address owner;
        uint256 clicks;
        uint256 impressions;
        uint256 rewards;
    }

    struct Campaign {
        uint256 number;
        string id;
        address owner;
        bool isLive;
        uint256 balance;
        uint256 endDate;
        address[] providerAddresses;
        mapping(address => Provider) providers;
    }

    // Interfaces
    IERC20 private stableToken;

    // Mappings
    mapping(string => Campaign) campaigns;
    string[] private campaignIds;

    // Address variables
    address public owner;
    address public feesReceiver;

    // Constants
    uint256 private constant DECIMALS = 18;
    uint256 public constant MAX_CAMPAIGN_BALANCE_ADDITION_FEE =
        (20 * 10 ** DECIMALS) / 100; // 20%
    uint256 public constant MAX_COST_PER_IMPRESSION =
        (1 * 10 ** DECIMALS) / 100; // 0.01
    uint256 public constant MAX_COST_PER_CLICK = (1 * 10 ** DECIMALS) / 10; // 0.10

    // Variables
    uint256 public totalRewardsDistributed = 0;
    uint256 public costPerImpression = (1 * 10 ** DECIMALS) / 1000;
    uint256 public costPerClick = (5 * 10 ** DECIMALS) / 100;
    uint256 public campaignBalanceAdditionFee = (20 * 10 ** DECIMALS) / 100;

    // Roles
    bytes32 public constant CAMPAIGN_MANAGER = keccak256("CAMPAIGN_MANAGER");

    // Events
    event SetCostPerImpression(uint256 _cost);
    event SetCostPerClick(uint256 _cost);
    event SetCampaignCreationFee(uint256 _fee);
    event SetFeesReceiver(address _receiver);
    event SetCampaign(string _campaignId);
    event SetCampaignIsLive(string _campaignId, uint256 _endDate);
    event RemoveCampaign(string _campaignId);
    event AddProvider(string _campaignId, address _providerAddress);
    event SetProvider(string _campaignId, address _providerAddress);
    event RemoveProvider(string _campaignId, address _providerAddress);
    event DistributeRewards(uint256 _distributedRewards);
    event ClaimRewards(
        string _campaignId,
        address _providerAddress,
        uint256 _rewards
    );

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    constructor() {
        owner = msg.sender;
        // feesReceiver = _feesReceiver;
        // stableToken = IERC20(_stableTokenAddress);

        // Grant the Admin role to the owner
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // Grant the Campaign Manager role to the owner so they could manage campaigns
        _grantRole(CAMPAIGN_MANAGER, msg.sender);
    }

    function tokenBalance() public view returns (uint256) {
        return stableToken.balanceOf(address(this));
    }

    function _transfer(address _to, uint256 _amount) private {
        stableToken.transfer(_to, _amount);
    }

    function _transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) private {
        stableToken.transferFrom(_from, _to, _amount);
    }

    function setStableToken(address _stableTokenAddress) public onlyOwner {
        stableToken = IERC20(_stableTokenAddress);
    }

    function setCostPerImpression(
        uint256 _costPerImpression
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _costPerImpression <= MAX_COST_PER_IMPRESSION,
            "Invalid cost per impression"
        );
        costPerImpression = _costPerImpression;
        emit SetCostPerImpression(costPerImpression);
    }

    function setCostPerClick(
        uint256 _setCostPerClick
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _setCostPerClick <= MAX_COST_PER_CLICK,
            "Invalid cost per click"
        );
        costPerClick = _setCostPerClick;
        emit SetCostPerClick(costPerClick);
    }

    function setCampaignBalanceAdditionFee(
        uint256 _campaignBalanceAdditionFee
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _campaignBalanceAdditionFee <= MAX_CAMPAIGN_BALANCE_ADDITION_FEE,
            "Invalid cost per balance addition"
        );
        campaignBalanceAdditionFee = _campaignBalanceAdditionFee;
        emit SetCampaignCreationFee(campaignBalanceAdditionFee);
    }

    function setFeesReceiver(
        address _feesReceiver
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        feesReceiver = _feesReceiver;
        emit SetFeesReceiver(feesReceiver);
    }

    function addCampaign(
        string memory _campaignId
    ) public onlyRole(CAMPAIGN_MANAGER) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.number == 0, "Cannot add a duplicate campaign");
        _campaign.id = _campaignId;
        _campaign.owner = msg.sender;
        _campaign.balance = 0;
        campaignIds.push(_campaignId);
        _campaign.number = campaignIds.length;
        emit SetCampaign(_campaignId);
    }

    function setCampaignIsLive(
        string memory _campaignId,
        bool _isLive,
        uint256 _endDate
    ) public onlyRole(CAMPAIGN_MANAGER) {
        require(
            campaigns[_campaignId].owner == msg.sender ||
                hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only the owner of the campaign can use this function"
        );
        campaigns[_campaignId].isLive = _isLive;
        campaigns[_campaignId].endDate = _endDate;
        emit SetCampaignIsLive(_campaignId, _endDate);
    }

    function removeCampaign(
        string memory _campaignId
    ) public onlyRole(CAMPAIGN_MANAGER) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.number > 0, "Campaign does not exist");
        uint256 index = _campaign.number - 1;
        if (index >= campaignIds.length) {
            return;
        }
        for (uint256 i = index; i < campaignIds.length - 1; i++) {
            campaignIds[i] = campaignIds[i + 1];
            campaigns[campaignIds[i]].number -= 1;
        }
        campaignIds.pop();
        delete (campaigns[_campaignId]);
        emit RemoveCampaign(_campaignId);
    }

    function addCampaignBalance(
        string memory _campaignId,
        uint256 _amount
    ) public onlyRole(CAMPAIGN_MANAGER) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(
            _campaign.owner == msg.sender,
            "Only the campaign owner can add balance to the campaign"
        );
        uint256 fee = (_amount * campaignBalanceAdditionFee) / 10 ** DECIMALS;
        uint256 amountAfterFee = _amount - fee;
        _transferFrom(msg.sender, address(this), _amount);
        _transfer(feesReceiver, fee);
        _campaign.balance += amountAfterFee;
    }

    function removeCampaignBalance(
        string memory _campaignId
    ) public onlyRole(CAMPAIGN_MANAGER) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(
            _campaign.owner == msg.sender,
            "Only the campaign owner can remove campaign balance"
        );
        _transfer(msg.sender, _campaign.balance);
        _campaign.balance = 0;
    }

    function returnAllCampaignBalancesToCampaignOwners()
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 c = 0; c < campaignIds.length; c++) {
            Campaign storage _campaign = campaigns[campaignIds[c]];
            _transfer(_campaign.owner, _campaign.balance);
            _campaign.balance = 0;
        }
    }

    function addProvider(string memory _campaignId) public {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.number > 0, "Campaign does not exist");
        Provider storage _provider = _campaign.providers[msg.sender];
        require(
            _provider.number == 0,
            "Cannot add a duplicate provider for the same campaign"
        );

        _provider.owner = msg.sender;
        _provider.impressions = 0;
        _provider.clicks = 0;
        _provider.rewards = 0;

        _campaign.providerAddresses.push(msg.sender);
        _provider.number = _campaign.providerAddresses.length;

        emit AddProvider(_campaignId, msg.sender);
    }

    function removeProvider(string memory _campaignId) public {
        emit RemoveProvider(_campaignId, msg.sender);
    }

    function setProviderData(
        string memory _campaignId,
        address _providerAddress,
        uint256 _clicks,
        uint256 _impressions
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.number > 0, "Campaign does not exist");
        Provider storage _provider = _campaign.providers[_providerAddress];
        require(_provider.number > 0, "Provider does not exist");

        _provider.clicks = _clicks;
        _provider.impressions = _impressions;

        emit SetProvider(_campaignId, _providerAddress);
    }

    function distributeRewards() public onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 rewardsAmount = 0;

        for (uint256 c = 0; c < campaignIds.length; c++) {
            string memory _campaignId = campaignIds[c];
            Campaign storage _campaign = campaigns[_campaignId];

            if (_campaign.isLive == false) {
                continue;
            }

            if (_campaign.balance <= 0) {
                continue;
            }

            for (uint256 p = 0; p < _campaign.providerAddresses.length; p++) {
                Provider storage _provider = _campaign.providers[
                    _campaign.providerAddresses[p]
                ];

                uint256 rewards = (_provider.clicks * costPerClick) +
                    (_provider.impressions * costPerImpression);

                // If the rewards calculated are the same as provider rewards don't add them
                // The same value means there are no changes
                if (_provider.rewards == rewards) {
                    continue;
                }

                // If rewards exceed campaign's balance set the rewards amount to the campaign's balance
                // If not, calculate the rewards and deduct them from campaign's balance
                if (rewards > _campaign.balance) {
                    _campaign.balance = 0;
                    _provider.rewards = _campaign.balance;
                    rewardsAmount += _campaign.balance;
                } else {
                    _campaign.balance = _campaign.balance - rewards;
                    _provider.rewards = rewards;
                    rewardsAmount += rewards;
                }
            }
        }

        totalRewardsDistributed += rewardsAmount;

        emit DistributeRewards(rewardsAmount);
    }

    function claimRewards(string memory _campaignId) public {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.number > 0, "Campaign does not exist");
        Provider storage _provider = _campaign.providers[msg.sender];
        require(
            _provider.owner == msg.sender,
            "Only original providers can claim their rewards"
        );
        uint256 claimable = _provider.rewards;

        // Transfer tokens to the Provider's address
        _transfer(msg.sender, claimable);

        // Reset Provider's stats
        // Makes it possible to start calculating rewards based on new values
        _provider.rewards = 0;
        _provider.clicks = 0;
        _provider.impressions = 0;

        emit ClaimRewards(_campaignId, msg.sender, claimable);
    }

    function getProvider(
        string memory _campaignId,
        address _providerAddress
    )
        public
        view
        returns (
            string memory campaignId,
            address providerAddress,
            uint256 number,
            uint256 rewards,
            uint256 clicks,
            uint256 impressions
        )
    {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.number > 0, "Campaign does not exist");
        Provider storage _provider = _campaign.providers[_providerAddress];
        require(_provider.number > 0, "Provider does not exist");
        return (
            _campaignId,
            _providerAddress,
            _provider.number,
            _provider.rewards,
            _provider.clicks,
            _provider.impressions
        );
    }

    function getCampaign(
        string memory _campaignId
    )
        public
        view
        returns (
            string memory campaignId,
            uint256 number,
            bool isLive,
            uint256 balance,
            uint256 providersCount
        )
    {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.number > 0, "Campaign does not exist");
        return (
            _campaignId,
            _campaign.number,
            _campaign.isLive,
            _campaign.balance,
            _campaign.providerAddresses.length
        );
    }
}
