// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract Tiny0xCampaign is AccessControl {
    struct Provider {
        uint256 index;
        address owner;
        uint256 clicks;
        uint256 impressions;
        uint256 rewards;
    }

    struct Campaign {
        uint256 index;
        string id;
        address owner;
        bool isLive;
        bool approved;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 balance;
        uint256 startDate;
        uint256 endDate;
        address[] providerAddresses;
        mapping(address => Provider) providers;
    }

    // Interfaces
    /**
     * @dev Stable Token interface. Used for campaign deposits and rewards distribution.
     */
    IERC20 private stableCoin;
    /**
     * @dev Tiny0x Link NFT interface. Used to allow only Link NFT holders to participate in campaigns.
     */
    IERC721 private linkNFT;

    // Mappings
    /**
     * @dev Campaigns Object that represents different campaigns by their ID
     */
    mapping(string => Campaign) private campaigns;

    /**
     * @dev A mapping of all the voters for any given campaign by ID
     */
    mapping(string => address[]) private voters;

    /**
     * @dev Provider Rewards. These rewards get accumulated from different campaign and can be claimed at any time.
     */
    mapping(address => uint256) private providerRewards;

    /**
     * @dev An array of Campaign IDs to keep track of them.
     */
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
    uint256 public constant MIN_COST_PER_CLICK = (5 * 10 ** DECIMALS) / 1000;
    uint256 public constant MIN_COST_PER_IMPRESSION =
        (1 * 10 ** DECIMALS) / 1000;
    uint256 public constant COST_PER_CLICK_COEFFICIENT = 12;
    uint256 public constant COST_PER_IMPRESSION_COEFFICIENT = 2;
    uint32 public constant CAMPAIGN_VOTING_PERIOD_DURATION = 7 days;

    // Variables
    uint256 public totalRewardsDistributed = 0;
    uint256 public costPerImpression = (4 * 10 ** DECIMALS) / 1000;
    uint256 public costPerClick = (5 * 10 ** DECIMALS) / 100;
    uint256 public campaignBalanceAdditionFee = (20 * 10 ** DECIMALS) / 100;
    uint256 public campaignVoteRewardPercentage = (5 * 10 ** DECIMALS) / 100;
    uint256 public campaignVotesThreshold = 500;

    // Roles
    bytes32 public constant CAMPAIGN_CREATOR = keccak256("CAMPAIGN_CREATOR");

    // Events
    event AddCampaignBalance(string _campaignId, uint256 _amount);
    event AddProvider(string _campaignId, address _providerAddress);
    event AddProviderData(string _campaignId, address _providerAddress);

    event ClaimRewards(address _providerAddress, uint256 _rewards);

    event DistributeRewards(uint256 _distributedRewards);

    event RemoveCampaign(string _campaignId);
    event RemoveProvider(string _campaignId, address _providerAddress);
    event ResetCampaignVotes(string _campaignId);
    event ResetProviderData(string _campaignId, address _providerAddress);
    event ReturnAllCampaignBalances();

    event SetCostPerImpression(uint256 _cost);
    event SetCostPerClick(uint256 _cost);
    event SetCampaignCreationFee(uint256 _fee);
    event SetCampaignVoteRewardPercentage(uint256 _fee);
    event SetFeesReceiver(address _receiver);
    event SetCampaign(string _campaignId);
    event SetCampaignIsLive(string _campaignId);
    event SetCampaignEndDate(string _campaignId, uint256 _endDate);

    event VoteForCampaign(string _campaignId, uint16 _vote);

    event WithdrawCampaignBalance(string _campaignId, uint256 _amount);

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    modifier onlyLinkNFTHolder() {
        if (msg.sender == owner) {
            _;
        }
        require(
            _linkNFTBalanceOf(msg.sender) > 0,
            "Only Tiny0x Link NFT holders can call this function."
        );
        _;
    }

    constructor() {
        owner = msg.sender;
        // feesReceiver = _feesReceiver;
        // stableCoin = IERC20(_stableCoinAddress);
        // linkNFT = IERC721(_linkNFTAddress);

        // Grant the Admin role to the owner
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        // Grant the Campaign Manager role to the owner so they could manage campaigns
        _grantRole(CAMPAIGN_CREATOR, msg.sender);
    }

    /**
     * @dev Returns the stablecoin balance of the contract
     */
    function getStableTokenBalance() public view returns (uint256) {
        return stableCoin.balanceOf(address(this));
    }

    /**
     * @dev The transfer method used to transfer tokens to a specified address
     */
    function _transfer(address _to, uint256 _amount) private {
        stableCoin.transfer(_to, _amount);
    }

    /**
     * @dev The transferFrom method used to transfer tokens from the user's wallet
     */
    function _transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) private {
        stableCoin.transferFrom(_from, _to, _amount);
    }

    /**
     * @dev Returns the stablecoin balance of the fees receiver wallet
     */
    function _getFeesReceiverBalance() private view returns (uint256) {
        return stableCoin.balanceOf(feesReceiver);
    }

    /**
     * @dev Returns the balance of the LINK NFT in the specified address
     */
    function _linkNFTBalanceOf(
        address _address
    ) private view returns (uint256) {
        return linkNFT.balanceOf(_address);
    }

    /**
     * @dev Calculates the price of CPI or CPC based on coefficients and units
     * @param _defaultPrice - The default price of the action (CPI or CPC)
     * @param _minPrice - The minimum price of the action (CPI or CPC)
     * @param _amount - The amount of clicks or impressions
     * @param _coefficient - The coefficient of the action. Clicks have a higher coefficient while impressions have a lower one
     */
    function _calculatePrice(
        uint256 _defaultPrice,
        uint256 _minPrice,
        uint256 _amount,
        uint256 _coefficient
    ) private pure returns (uint256) {
        unchecked {
            uint256 priceDecrease = (_defaultPrice *
                ((_amount / (_coefficient / (_coefficient / 2))) * 10 ** 14)) /
                10 ** DECIMALS;
            uint256 resultingPrice = _defaultPrice - priceDecrease;
            return
                resultingPrice > 0 &&
                    resultingPrice > _minPrice &&
                    resultingPrice < _defaultPrice
                    ? resultingPrice
                    : _minPrice;
        }
    }

    /**
     * @dev Sets the contract address for the stablecoin used by this contract
     */
    function setStableCoin(address _stableCoinAddress) public onlyOwner {
        stableCoin = IERC20(_stableCoinAddress);
    }

    /**
     * @dev Sets the LINK NFT contract address
     */
    function setLinkNFT(address _linkNFTAddress) public onlyOwner {
        linkNFT = IERC721(_linkNFTAddress);
    }

    /**
     * @dev Sets the votes threshold required for the campaign to become approved or declined
     */
    function setCampaignVotesThreshold(
        uint256 _campaignVotesThreshold
    ) public onlyOwner {
        campaignVotesThreshold = _campaignVotesThreshold;
    }

    /**
     * @dev Sets the Cost Per Impression (CPI)
     * Emits SetCostPerImpression
     */
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

    /**
     * @dev Sets the Cost Per Click (CPC)
     * Emits SetCostPerClick
     */
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

    /**
     * @dev Sets the campaign balance addition fee which is deducted whenever the campaign adds balance
     * Emits SetCampaignCreationFee
     */
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

    /**
     * @dev Sets the rewards percentage used for rewarding voters
     * Emits SetCampaignVoteRewardPercentage
     */
    function setCampaignVoteRewardPercentage(
        uint256 _campaignVoteRewardPercentage
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        campaignVoteRewardPercentage = _campaignVoteRewardPercentage;
        emit SetCampaignVoteRewardPercentage(campaignVoteRewardPercentage);
    }

    /**
     * @dev Sets the fees receiver wallet
     * Emits SetFeesReceiver
     */
    function setFeesReceiver(
        address _feesReceiver
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        feesReceiver = _feesReceiver;
        emit SetFeesReceiver(feesReceiver);
    }

    /**
     * @dev Allows to vote for or agains a campaign
     * This function tracks all voters and prevents them from voting twice for the same campaign
     * This function approves or declines the campaign based on the votes threshold and the start date
     * This function calculates the rewards for voting for/against the campaign and assigns it to the voter
     * @param _campaignId - Campaign ID
     * @param _vote - 0 = against, 1 = for
     * Emits VoteForCampaign
     */
    function voteForCampaign(
        string memory _campaignId,
        uint16 _vote
    ) public onlyLinkNFTHolder {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.index > 0, "Campaign does not exist");

        require(
            _campaign.approved == false && _campaign.isLive == false,
            "Cannot vote on approved and live campaigns"
        );

        for (uint256 i = 0; i < voters[_campaignId].length; i++) {
            require(
                voters[_campaignId][i] != msg.sender,
                "You cannot vote for the same campaign again"
            );
        }

        voters[_campaignId].push(msg.sender);

        // Voting against
        if (_vote == 0) {
            _campaign.votesAgainst += 1;
        }

        // Voting for
        if (_vote == 1) {
            _campaign.votesFor += 1;
            addProvider(_campaignId);
        }

        if (
            block.timestamp >= _campaign.startDate &&
            _campaign.votesAgainst < campaignVotesThreshold
        ) {
            _campaign.approved = true;
            _campaign.startDate = block.timestamp;
            delete (voters[_campaignId]);
        }

        if (
            _campaign.votesFor >= campaignVotesThreshold &&
            _campaign.votesAgainst < campaignVotesThreshold
        ) {
            _campaign.approved = true;
            _campaign.startDate = block.timestamp;
            delete (voters[_campaignId]);
        }

        if (
            _campaign.votesAgainst >= campaignVotesThreshold &&
            _campaign.votesFor < campaignVotesThreshold
        ) {
            _campaign.approved = false;
            _campaign.endDate = block.timestamp;
        }

        uint256 feesReceiverBalance = _getFeesReceiverBalance();

        uint256 sumOfVotes = _campaign.votesFor + _campaign.votesAgainst;

        uint256 voteRewards = (feesReceiverBalance *
            (campaignVoteRewardPercentage / sumOfVotes)) / 10 ** DECIMALS;

        if (
            voteRewards < feesReceiverBalance &&
            campaignVoteRewardPercentage > 0
        ) {
            _transferFrom(feesReceiver, address(this), voteRewards);
            providerRewards[msg.sender] += voteRewards;
        }

        emit VoteForCampaign(_campaignId, _vote);
    }

    /**
     * @dev Adds a new campaign
     * @param _campaignId - Campaign ID
     * @param _endDate - End date in timestamp format
     * Emits SetCampaign
     */
    function addCampaign(
        string memory _campaignId,
        uint256 _endDate
    ) public onlyRole(CAMPAIGN_CREATOR) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.index == 0, "Cannot add a duplicate campaign");
        _campaign.id = _campaignId;
        _campaign.owner = msg.sender;
        _campaign.balance = 0;
        _campaign.startDate = block.timestamp + CAMPAIGN_VOTING_PERIOD_DURATION;
        _campaign.endDate = _endDate;
        _campaign.approved = false;
        campaignIds.push(_campaignId);
        _campaign.index = campaignIds.length;
        emit SetCampaign(_campaignId);
    }

    /**
     * @dev Allows to reset all campaign votes to 0
     * @param _campaignId - Campaign ID
     * Emits ResetCampaignVotes
     */
    function resetCampaignVotes(
        string memory _campaignId
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(campaigns[_campaignId].index > 0, "Campaign does not exist");
        _campaign.votesAgainst = 0;
        _campaign.votesFor = 0;
        emit ResetCampaignVotes(_campaignId);
    }

    /**
     * @dev Sets the campaign to isLive == false or isLive == true
     * @param _campaignId - Campaign ID
     * @param _isLive - Boolean indicating if the campaign is live or not
     * Emits SetCampaignIsLive
     */
    function setCampaignIsLive(
        string memory _campaignId,
        bool _isLive
    ) public onlyRole(CAMPAIGN_CREATOR) {
        require(
            campaigns[_campaignId].owner == msg.sender ||
                hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only the owner of the campaign can use this function"
        );
        campaigns[_campaignId].isLive = _isLive;
        emit SetCampaignIsLive(_campaignId);
    }

    /**
     * @dev Sets the campaign to approved == false or approved == true
     * @param _campaignId - Campaign ID
     * @param _approved - Boolean indicating whether the campaign is approved
     * Emits SetCampaignIsLive
     */
    function setCampaignApproved(
        string memory _campaignId,
        bool _approved
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(campaigns[_campaignId].index > 0, "Campaign does not exist");
        campaigns[_campaignId].approved = _approved;
        emit SetCampaignIsLive(_campaignId);
    }

    /**
     * @dev Allows the owner of the campaign to set the end date
     * @param _campaignId - Campaign ID
     * @param _endDate - End date in timestamp format
     * Emits SetCampaignEndDate
     */
    function setCampaignEndDate(
        string memory _campaignId,
        uint256 _endDate
    ) public onlyRole(CAMPAIGN_CREATOR) {
        require(
            campaigns[_campaignId].owner == msg.sender ||
                hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only the owner of the campaign can use this function"
        );
        campaigns[_campaignId].endDate = _endDate;
        emit SetCampaignEndDate(_campaignId, _endDate);
    }

    /**
     * @dev Allows the owner of the campaign to remove their campaign
     * @param _campaignId - Campaign ID
     * Emits RemoveCampaign
     */
    function removeCampaign(
        string memory _campaignId
    ) public onlyRole(CAMPAIGN_CREATOR) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.index > 0, "Campaign does not exist");
        uint256 index = _campaign.index - 1;
        if (index >= campaignIds.length) {
            return;
        }
        for (uint256 i = index; i < campaignIds.length - 1; i++) {
            campaignIds[i] = campaignIds[i + 1];
            campaigns[campaignIds[i]].index -= 1;
        }
        campaignIds.pop();
        delete (campaigns[_campaignId]);
        emit RemoveCampaign(_campaignId);
    }

    /**
     * @dev Allows the owner of the campaign to add balance to their campaign
     * @param _campaignId - Campaign ID
     * @param _amount - The amount to be added to the campaign balance
     * Note: This function incurs a fee. The fee is transferred to the fee receiver. The remainder is left in the contract and assigned to the campaign balance.
     * Emits AddCampaignBalance
     */
    function addCampaignBalance(
        string memory _campaignId,
        uint256 _amount
    ) public onlyRole(CAMPAIGN_CREATOR) {
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
        emit AddCampaignBalance(_campaignId, amountAfterFee);
    }

    /**
     * @dev Allows the owner of the campaign to withdraw their campaign balance
     * @param _campaignId - Campaign ID
     * Emits WithdrawCampaignBalance
     */
    function withdrawCampaignBalance(
        string memory _campaignId
    ) public onlyRole(CAMPAIGN_CREATOR) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(
            _campaign.owner == msg.sender,
            "Only the campaign owner can remove campaign balance"
        );
        uint256 balance = _campaign.balance;
        _transfer(msg.sender, balance);
        _campaign.balance = 0;
        emit WithdrawCampaignBalance(_campaignId, balance);
    }

    /**
     * @dev Returns all of the campaign balances to their owners
     * Emits ReturnAllCampaignBalances
     */
    function returnAllCampaignBalancesToCampaignOwners()
        public
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        for (uint256 c = 0; c < campaignIds.length; c++) {
            Campaign storage _campaign = campaigns[campaignIds[c]];
            _transfer(_campaign.owner, _campaign.balance);
            _campaign.balance = 0;
        }
        emit ReturnAllCampaignBalances();
    }

    /**
     * @dev Adds a new provider to the campaign. The provider is the message sender.
     * @param _campaignId - Campaign ID
     * Emits AddProvider
     */
    function addProvider(string memory _campaignId) public {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.index > 0, "Campaign does not exist");
        Provider storage _provider = _campaign.providers[msg.sender];
        require(
            _provider.index == 0,
            "Cannot add a duplicate provider for the same campaign"
        );

        _provider.owner = msg.sender;
        _provider.impressions = 0;
        _provider.clicks = 0;
        _provider.rewards = 0;

        _campaign.providerAddresses.push(msg.sender);
        _provider.index = _campaign.providerAddresses.length;

        emit AddProvider(_campaignId, msg.sender);
    }

    /**
     * @dev Removes provider from the campaign
     * @param _campaignId - Campaign ID
     * Emits RemoveProvider
     */
    function removeProviderFromCampaign(string memory _campaignId) public {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.index > 0, "Campaign does not exist");
        Provider storage _provider = _campaign.providers[msg.sender];
        require(_provider.index > 0, "Provider does not exist");
        uint256 index = _provider.index - 1;

        if (index >= _campaign.providerAddresses.length) {
            return;
        }

        for (
            uint256 i = index;
            i < _campaign.providerAddresses.length - 1;
            i++
        ) {
            _campaign.providerAddresses[i] = _campaign.providerAddresses[i + 1];
            _campaign.providers[_campaign.providerAddresses[i]].index -= 1;
        }

        _campaign.providerAddresses.pop();
        delete (_campaign.providers[msg.sender]);
        emit RemoveProvider(_campaignId, msg.sender);
    }

    /**
     * @dev Adds Clicks and Impressions to the provider address
     * @param _campaignId - Campaign ID
     * @param _providerAddress = Address of the provider participating in the campaign
     * @param _clicks - Number of clicks the provider has generated
     * @param _impressions - Number of impressions the provider has generated
     * Emits AddProviderData
     */
    function addProviderData(
        string memory _campaignId,
        address _providerAddress,
        uint256 _clicks,
        uint256 _impressions
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.index > 0, "Campaign does not exist");
        Provider storage _provider = _campaign.providers[_providerAddress];
        require(_provider.index > 0, "Provider does not exist");

        _provider.clicks += _clicks;
        _provider.impressions += _impressions;

        emit AddProviderData(_campaignId, _providerAddress);
    }

    /**
     * @dev Resets the provider data to 0
     * @param _campaignId - Campaign ID
     * @param _providerAddress - Address of the provider participating in the Campaign
     * Emits ResetProviderData
     */
    function resetProvider(
        string memory _campaignId,
        address _providerAddress
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.index > 0, "Campaign does not exist");
        Provider storage _provider = _campaign.providers[_providerAddress];
        require(_provider.index > 0, "Provider does not exist");

        _provider.clicks = 0;
        _provider.impressions = 0;
        _provider.rewards = 0;

        emit ResetProviderData(_campaignId, _providerAddress);
    }

    /**
     * @dev Distributes rewards from all campaigns to all providers participating in them
     * Calculates the CPC and CPI in a declining pattern reducing overall cost when CPI/CPC is increasing
     * Emits DistributeRewards
     */
    function distributeRewards() public onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 rewardsAmount = 0;

        for (uint256 c = 0; c < campaignIds.length; c++) {
            string memory _campaignId = campaignIds[c];
            Campaign storage _campaign = campaigns[_campaignId];

            if (
                _campaign.isLive == false ||
                _campaign.endDate <= block.timestamp ||
                _campaign.approved == false ||
                _campaign.balance == 0
            ) {
                continue;
            }

            for (uint256 p = 0; p < _campaign.providerAddresses.length; p++) {
                Provider storage _provider = _campaign.providers[
                    _campaign.providerAddresses[p]
                ];

                uint256 _cpc = _calculatePrice(
                    costPerClick,
                    MIN_COST_PER_CLICK,
                    _provider.clicks,
                    COST_PER_CLICK_COEFFICIENT
                );

                uint256 _cpi = _calculatePrice(
                    costPerImpression,
                    MIN_COST_PER_IMPRESSION,
                    _provider.impressions,
                    COST_PER_IMPRESSION_COEFFICIENT
                );

                uint256 rewards = (_provider.clicks * _cpc) +
                    (_provider.impressions * _cpi);

                // If calculated rewards are lower than the provider rewards, ignore.
                if (rewards <= _provider.rewards) {
                    continue;
                }

                // Find the difference between new and old rewards
                uint256 rewardsDelta = rewards - _provider.rewards;

                // If the rewards difference exceeds the campaign balance, use all of the balance
                // If not, deduct the difference and add it to the provider rewards
                if (rewardsDelta >= _campaign.balance) {
                    _provider.rewards = _campaign.balance;
                    rewardsAmount += _campaign.balance;
                    providerRewards[msg.sender] += _campaign.balance;
                    _campaign.balance = 0;
                } else {
                    _campaign.balance -= rewardsDelta;
                    _provider.rewards += rewardsDelta;
                    rewardsAmount += rewardsDelta;
                    providerRewards[msg.sender] += rewardsDelta;
                }
            }
        }

        totalRewardsDistributed += rewardsAmount;
        emit DistributeRewards(rewardsAmount);
    }

    /**
     * @dev Allows the sender to claim his rewards from voting or reward distribution through running ads
     * Emits ClaimRewards
     */
    function claimRewards() public {
        uint256 claimable = providerRewards[msg.sender];
        require(claimable > 0, "You cannot claim a 0 value reward.");
        _transfer(msg.sender, claimable);
        providerRewards[msg.sender] = 0;
        emit ClaimRewards(msg.sender, claimable);
    }

    /**
     * @dev Gets the message sender rewards amount
     */
    function getRewards() public view returns (uint256) {
        return providerRewards[msg.sender];
    }

    function getProviderByCampaignId(
        string memory _campaignId,
        address _providerAddress
    )
        public
        view
        returns (
            string memory campaignId,
            address providerAddress,
            uint256 index,
            uint256 totalRewards,
            uint256 clicks,
            uint256 impressions
        )
    {
        Campaign storage _campaign = campaigns[_campaignId];
        require(_campaign.index > 0, "Campaign does not exist");
        Provider storage _provider = _campaign.providers[_providerAddress];
        require(_provider.index > 0, "Provider does not exist");
        return (
            _campaignId,
            _providerAddress,
            _provider.index,
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
            uint256 index,
            bool isLive,
            bool approved,
            uint256 votesFor,
            uint256 votesAgainst,
            uint256 balance,
            uint256 startDate,
            uint256 endDate,
            uint256 providersCount
        )
    {
        Campaign storage _campaign = campaigns[_campaignId];

        require(_campaign.index > 0, "Campaign does not exist");

        return (
            _campaignId,
            _campaign.index,
            _campaign.isLive,
            _campaign.approved,
            _campaign.votesFor,
            _campaign.votesAgainst,
            _campaign.balance,
            _campaign.startDate,
            _campaign.endDate,
            _campaign.providerAddresses.length
        );
    }
}
