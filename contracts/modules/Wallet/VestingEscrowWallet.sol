pragma solidity ^0.4.24;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "./IWallet.sol";

/**
 * @title Wallet for core vesting escrow functionality
 */
contract VestingEscrowWallet is IWallet {
    using SafeMath for uint256;

    bytes32 public constant ADMIN = "ADMIN";

    struct Schedule {
        uint256 numberOfTokens;
        uint256 releasedTokens;
        uint256 availableTokens;
        uint256 duration;
        uint256 frequency;
        uint256 startTime;
    }

    struct Data {
        uint256 index;
        Schedule[] schedules;
    }

    struct Template {
        uint256 numberOfTokens;
        uint256 duration;
        uint256 frequency;
    }

    enum State {CREATED, STARTED, COMPLETED}
    //TODO add method for getting state

    address public treasury;
    uint256 public unassignedTokens;

    mapping (address => Data) public dataMap;
    address[] public beneficiaries;

    Template[] public templates;

    event AddSchedule(
        address indexed _beneficiary,
        uint256 _numberOfTokens,
        uint256 _duration,
        uint256 _frequency,
        uint256 _startTime
    );
    event ModifySchedule(
        address indexed _beneficiary,
        uint256 _index,
        uint256 _numberOfTokens,
        uint256 _duration,
        uint256 _frequency,
        uint256 _startTime
    );
    event RevokeSchedules(address indexed _beneficiary);
    event RevokeSchedule(address indexed _beneficiary, uint256 _index);
    event DepositTokens(uint256 _numberOfTokens);
    event SendToTreasury(uint256 _numberOfTokens);
    event SendTokens(address indexed _beneficiary, uint256 _numberOfTokens);
    event AddTemplate(uint256 _numberOfTokens, uint256 _duration, uint256 _frequency, uint256 _index);
    event RemoveTemplate(uint256 _index);

    /**
     * @notice Constructor
     * @param _securityToken Address of the security token
     * @param _polyAddress Address of the polytoken
     */
    constructor (address _securityToken, address _polyAddress)
    public
    Module(_securityToken, _polyAddress)
    {
    }

    /**
     * @notice Function used to initialize the different variables
     * @param _treasury Address of the treasury
     */
    function configure(address _treasury) public onlyFactory {
        require(_treasury != address(0), "Invalid address");
        treasury = _treasury;
    }

    /**
     * @notice This function returns the signature of the configure function
     */
    function getInitFunction() public pure returns (bytes4) {
        return bytes4(keccak256("configure(address)"));
    }

    /**
     * @notice Used to deposit tokens from treasury
     */
    function depositTokens(uint256 _numberOfTokens) external withPerm(ADMIN) {
        _depositTokens(_numberOfTokens);
    }

    function _depositTokens(uint256 _numberOfTokens) internal {
        require(_numberOfTokens > 0, "Should be greater than zero");
        ISecurityToken(securityToken).transferFrom(treasury, this, _numberOfTokens);
        unassignedTokens = unassignedTokens.add(_numberOfTokens);
        emit DepositTokens(_numberOfTokens);
    }

    /**
     * @notice Sends unassigned tokens to treasury
     */
    function sendToTreasury() external withPerm(ADMIN) {
        uint256 amount = unassignedTokens;
        unassignedTokens = 0;
        ISecurityToken(securityToken).transfer(treasury, amount);
        emit SendToTreasury(amount);
    }

    /**
     * @notice Pushes available tokens to beneficiary
     * @param _beneficiary beneficiary's address
     */
    function pushAvailableTokens(address _beneficiary) public withPerm(ADMIN) {
        _sendTokens(_beneficiary);
    }

    /**
     * @notice Used to withdraw available tokens by beneficiary
     */
    function withdrawAvailableTokens() external {
        _sendTokens(msg.sender);
    }

    /**
     * @notice Add template
     * @param _numberOfTokens number of tokens
     * @param _duration vesting duration
     * @param _frequency vesting frequency
     */
    function addTemplate(uint256 _numberOfTokens, uint256 _duration, uint256 _frequency) external withPerm(ADMIN) {
        _validateTemplate(_numberOfTokens, _duration, _frequency);
        templates.push(Template(_numberOfTokens, _duration, _frequency));
        emit AddTemplate(_numberOfTokens, _duration, _frequency, templates.length - 1);
    }

    /**
     * @notice Removes template
     * @param _index index of the template
     */
    function removeTemplate(uint256 _index) external withPerm(ADMIN) {
        require(_index < templates.length, "Template not found");
        if (_index != templates.length - 1) {
            templates[_index] = templates[templates.length - 1];
        }
        templates.length--;
        emit RemoveTemplate(_index);
    }

    /**
     * @notice Returns count of templates
     * @return count of templates
     */
    function getTemplateCount() external view returns(uint256) {
        return templates.length;
    }

    /**
     * @notice Adds vesting schedules for each of beneficiary
     * @param _beneficiary beneficiary's addresses
     * @param _numberOfTokens number of tokens
     * @param _duration vesting duration
     * @param _frequency vesting frequency
     * @param _startTime vesting start time
     */
    function addSchedule(
        address _beneficiary,
        uint256 _numberOfTokens,
        uint256 _duration,
        uint256 _frequency,
        uint256 _startTime
    )
        public
        withPerm(ADMIN)
    {
        _validateSchedule(_beneficiary, _numberOfTokens, _duration, _frequency, _startTime);
        if (_numberOfTokens > unassignedTokens) {
            _depositTokens(_numberOfTokens.sub(unassignedTokens));
        }
        unassignedTokens = unassignedTokens.sub(_numberOfTokens);
        //add beneficiary to the schedule list only if adding first schedule
        if (dataMap[_beneficiary].schedules.length == 0) {
            dataMap[_beneficiary].index = beneficiaries.length;
            beneficiaries.push(_beneficiary);
        }
        dataMap[_beneficiary].schedules.push(Schedule(_numberOfTokens, 0, 0, _duration, _frequency, _startTime));
        emit AddSchedule(_beneficiary, _numberOfTokens, _duration, _frequency, _startTime);
    }

    /**
     * @notice Adds vesting schedules from template for each of beneficiary
     * @param _beneficiary beneficiary's addresses
     * @param _index index of the template
     * @param _startTime vesting start time
     */
    function addScheduleFromTemplate(address _beneficiary, uint256 _index, uint256 _startTime) external withPerm(ADMIN) {
        _addScheduleFromTemplate(_beneficiary, _index, _startTime);
    }

    function _addScheduleFromTemplate(address _beneficiary, uint256 _index, uint256 _startTime) internal {
        require(_index < templates.length, "Template not found");
        Template memory template = templates[_index];
        addSchedule(_beneficiary, template.numberOfTokens, template.duration, template.frequency, _startTime);
    }

    /**
     * @notice Modifies vesting schedules for each of beneficiary
     * @param _beneficiary beneficiary's addresses
     * @param _index index of schedule
     * @param _numberOfTokens number of tokens
     * @param _duration vesting duration
     * @param _frequency vesting frequency
     * @param _startTime vesting start time
     */
    function modifySchedule(
        address _beneficiary,
        uint256 _index,
        uint256 _numberOfTokens,
        uint256 _duration,
        uint256 _frequency,
        uint256 _startTime
    )
        public
        withPerm(ADMIN)
    {
        _validateSchedule(_beneficiary, _numberOfTokens, _duration, _frequency, _startTime);
        require(_index < dataMap[_beneficiary].schedules.length, "Schedule not found");
        Schedule storage schedule = dataMap[_beneficiary].schedules[_index];
        /*solium-disable-next-line security/no-block-members*/
        require(now < schedule.startTime, "Schedule started");
        if (_numberOfTokens <= schedule.numberOfTokens) {
            unassignedTokens = unassignedTokens.add(schedule.numberOfTokens - _numberOfTokens);
        } else {
            if (_numberOfTokens - schedule.numberOfTokens > unassignedTokens) {
                _depositTokens(_numberOfTokens - schedule.numberOfTokens - unassignedTokens);
            }
            unassignedTokens = unassignedTokens.sub(_numberOfTokens - schedule.numberOfTokens);
        }
        dataMap[_beneficiary].schedules[_index] = Schedule(_numberOfTokens, 0, 0, _duration, _frequency, _startTime);
        emit ModifySchedule(_beneficiary, _index, _numberOfTokens, _duration, _frequency, _startTime);
    }

    /**
     * @notice Revokes beneficiary's schedule
     * @param _beneficiary beneficiary's address
     * @param _index index of the schedule
     */
    function revokeSchedule(address _beneficiary, uint256 _index) external withPerm(ADMIN) {
        require(_beneficiary != address(0), "Invalid address");
        require(_index < dataMap[_beneficiary].schedules.length, "Schedule not found");
        Schedule[] storage schedules = dataMap[_beneficiary].schedules;
        unassignedTokens = unassignedTokens.add(schedules[_index].numberOfTokens - schedules[_index].releasedTokens);
        schedules[_index] = schedules[schedules.length - 1];
        schedules.length--;
        if (schedules.length == 0) {
            _revokeSchedules(_beneficiary);
        }
        emit RevokeSchedule(_beneficiary, _index);
    }


    /**
     * @notice Revokes all beneficiary's schedules
     * @param _beneficiary beneficiary's address
     */
    function revokeSchedules(address _beneficiary) public withPerm(ADMIN) {
        require(_beneficiary != address(0), "Invalid address");
        Data storage data = dataMap[_beneficiary];
        for (uint256 i = 0; i < data.schedules.length; i++) {
            unassignedTokens = unassignedTokens.add(data.schedules[i].numberOfTokens - data.schedules[i].releasedTokens);
        }
        delete dataMap[_beneficiary].schedules;
        _revokeSchedules(_beneficiary);
        emit RevokeSchedules(_beneficiary);
    }

    /**
     * @notice Returns beneficiary's schedule
     * @param _beneficiary beneficiary's address
     * @param _index index of the schedule
     * @return beneficiary's schedule
     */
    function getSchedule(address _beneficiary, uint256 _index) external view returns(uint256, uint256, uint256, uint256) {
        require(_beneficiary != address(0), "Invalid address");
        require(_index < dataMap[_beneficiary].schedules.length, "Schedule not found");
        Schedule storage schedule = dataMap[_beneficiary].schedules[_index];
        return (
            schedule.numberOfTokens,
            schedule.duration,
            schedule.frequency,
            schedule.startTime
        );
    }

    /**
     * @notice Returns count of beneficiary's schedules
     * @param _beneficiary beneficiary's address
     * @return count of beneficiary's schedules
     */
    function getScheduleCount(address _beneficiary) external view returns(uint256) {
        require(_beneficiary != address(0), "Invalid address");
        return dataMap[_beneficiary].schedules.length;
    }

    /**
     * @notice Returns available tokens for beneficiary
     * @param _beneficiary beneficiary's address
     * @return available tokens for beneficiary
     */
    function getAvailableTokens(address _beneficiary) external view returns(uint256) {
        return _getAvailableTokens(_beneficiary);
    }

    function _getAvailableTokens(address _beneficiary) internal view returns(uint256) {
        require(_beneficiary != address(0));
        uint256 availableTokens;
        for (uint256 i = 0; i < dataMap[_beneficiary].schedules.length; i++) {
            availableTokens = availableTokens.add(dataMap[_beneficiary].schedules[i].availableTokens);
        }
        return availableTokens;
    }

    /**
     * @notice Used to bulk send available tokens for each of beneficiaries
     * @param _beneficiaries array of beneficiary's addresses
     */
    function pushAvailableTokensMulti(address[] _beneficiaries) external withPerm(ADMIN) {
        require(_beneficiaries.length > 1, "Array size should be greater than one");
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            pushAvailableTokens(_beneficiaries[i]);
        }
    }

    /**
     * @notice Used to bulk add vesting schedules for each of beneficiaries
     * @param _beneficiaries array of beneficiary's addresses
     * @param _numberOfTokens number of tokens
     * @param _duration vesting duration
     * @param _frequency vesting frequency
     * @param _startTime vesting start time
     */
    function addScheduleMulti(
        address[] _beneficiaries,
        uint256 _numberOfTokens,
        uint256 _duration,
        uint256 _frequency,
        uint256 _startTime
    )
        external
        withPerm(ADMIN)
    {
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            addSchedule(_beneficiaries[i], _numberOfTokens, _duration, _frequency, _startTime);
        }
    }

    /**
     * @notice Used to bulk add vesting schedules from template for each of beneficiaries
     * @param _beneficiaries array of beneficiary's addresses
     * @param _index index of the template
     * @param _startTime vesting start time
     */
    function addScheduleFromTemplateMulti(address[] _beneficiaries, uint256 _index, uint256 _startTime) external withPerm(ADMIN) {
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            _addScheduleFromTemplate(_beneficiaries[i], _index, _startTime);
        }
    }

    /**
     * @notice Used to bulk revoke vesting schedules for each of beneficiaries
     * @param _beneficiaries array of beneficiary's addresses
     */
    function revokeSchedulesMulti(address[] _beneficiaries) external withPerm(ADMIN) {
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            revokeSchedules(_beneficiaries[i]);
        }
    }

    /**
     * @notice Used to bulk modify vesting schedules for each of beneficiaries
     * @param _beneficiaries array of beneficiary's addresses
     * @param _indexes array of beneficiary's indexes of schedule
     * @param _numberOfTokens number of tokens
     * @param _duration vesting duration
     * @param _frequency vesting frequency
     * @param _startTime vesting start time
     */
    function modifyScheduleMulti(
        address[] _beneficiaries,
        uint256[] _indexes,
        uint256 _numberOfTokens,
        uint256 _duration,
        uint256 _frequency,
        uint256 _startTime
    )
        external
        withPerm(ADMIN)
    {
        require(_beneficiaries.length == _indexes.length, "Arrays sizes mismatch");
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            modifySchedule(_beneficiaries[i], _indexes[i], _numberOfTokens, _duration, _frequency, _startTime);
        }
    }

    function _validateSchedule(
        address _beneficiary,
        uint256 _numberOfTokens,
        uint256 _duration,
        uint256 _frequency,
        uint256 _startTime
    )
        internal
        view
    {
        require(_beneficiary != address(0), "Invalid address");
        _validateTemplate(_numberOfTokens, _duration, _frequency);
        require(now < _startTime, "Date in the past");
    }

    function _validateTemplate(uint256 _numberOfTokens, uint256 _duration, uint256 _frequency) internal pure {
        require(_numberOfTokens > 0, "Zero amount");
        require(_duration % _frequency == 0, "Duration and frequency mismatch");
        uint256 periodCount = _duration.div(_frequency);
        require(_numberOfTokens % periodCount == 0, "Tokens and periods mismatch");
    }

    function _sendTokens(address _beneficiary) internal {
        uint256 amount = _getAvailableTokens(_beneficiary);
        require(amount > 0, "No available tokens");
        for (uint256 i = 0; i < dataMap[_beneficiary].schedules.length; i++) {
            dataMap[_beneficiary].schedules[i].availableTokens = 0;
        }
        ISecurityToken(securityToken).transfer(_beneficiary, amount);
        emit SendTokens(_beneficiary, amount);
    }

    /**
     * @notice manually triggers update outside for beneficiary's schedule (can be used to reduce user gas costs)
     * @param _beneficiary beneficiary's address of the schedule
     */
    function update(address _beneficiary) external withPerm(ADMIN) {
        _update(_beneficiary);
    }

    function _update(address _beneficiary) internal {
        Data storage data = dataMap[_beneficiary];
        for (uint256 i = 0; i < data.schedules.length; i++) {
            Schedule storage schedule = data.schedules[i];
            if (schedule.releasedTokens < schedule.numberOfTokens) {
                uint256 periodCount = schedule.duration.div(schedule.frequency);
                /*solium-disable-next-line security/no-block-members*/
                uint256 periodNumber = (now.sub(schedule.startTime)).div(schedule.frequency);
                if (periodNumber > periodCount) {
                    periodNumber = periodCount;
                }
                uint256 releasedTokens = schedule.numberOfTokens.mul(periodNumber).div(periodCount);
                if (schedule.releasedTokens < releasedTokens) {
                    schedule.availableTokens = schedule.availableTokens.add(releasedTokens - schedule.releasedTokens);
                    schedule.releasedTokens = releasedTokens;
                }
            }
        }
    }

    /**
     * @notice manually triggers update outside for all schedules (can be used to reduce user gas costs)
     */
    function updateAll() external withPerm(ADMIN) {
        _updateAll();
    }

    function _updateAll() internal {
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            _update(beneficiaries[i]);
        }
    }

    function _revokeSchedules(address _beneficiary) internal {
        //can be removed
        if (_getAvailableTokens(_beneficiary) == 0) {
            uint256 index = dataMap[_beneficiary].index;
            beneficiaries[index] = beneficiaries[beneficiaries.length - 1];
            beneficiaries.length--;
            if (index != beneficiaries.length) {
                dataMap[beneficiaries[index]].index = index;
            }
            delete dataMap[_beneficiary];
        }
    }

    /**
     * @notice Return the permissions flag that are associated with VestingEscrowWallet
     */
    function getPermissions() public view returns(bytes32[]) {
        bytes32[] memory allPermissions = new bytes32[](1);
        allPermissions[0] = ADMIN;
        return allPermissions;
    }

}
