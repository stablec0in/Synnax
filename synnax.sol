// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
// swapp 0x6A42684582716E8AA0faEa21362A7346CD7f8221

// INTERFACE
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBentoBox {
    function setMasterContractApproval(
        address user,
        address masterContract,
        bool approved,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    
    function withdraw(
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 share
    ) external returns (uint256 amountOut, uint256 shareOut);
}

interface ICauldron {
    function cook(
        uint8[] calldata actions,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external payable returns (uint256 value1, uint256 value2);

    function totalBorrow() external view returns (uint128 elastic, uint128 base);
    function userBorrowPart(address user) external view returns (uint256 amount);
}

interface ISwapper {
    // return amount_out
    function swap(address asset_in,address asset_out,uint256 amount_in,uint256 min_amount_out) external returns (uint256);
}


contract CauldronHelper {
    
    // owner master a accès a tout
    address public owner;

    // executeur a acces au fonction buy et sell non sensible
    address public executer;

    IBentoBox public immutable bentoBox;
    ICauldron public immutable cauldron;
    
    
    address public master;
    address public swapper;
    
    // assets 
    IERC20 syusd;
    IERC20 usdc;

    // log in out 
    uint256 sell_amount;
    uint256 buy_amount;

    // update rates parameter 
    bool    update1;
    uint256 update2;
    uint256 update3;
    
    // pour le control de rebuy de l'owner

    bool normal;


    // constante pour les actions
    // Functions that need accrue to be called
    uint8 internal constant ACTION_REPAY = 2;
    uint8 internal constant ACTION_REMOVE_COLLATERAL = 4;
    uint8 internal constant ACTION_BORROW = 5;
    uint8 internal constant ACTION_GET_REPAY_SHARE = 6;
    uint8 internal constant ACTION_GET_REPAY_PART = 7;
    uint8 internal constant ACTION_ACCRUE = 8;

    // Functions that don't need accrue to be called
    uint8 internal constant ACTION_ADD_COLLATERAL = 10;
    uint8 internal constant ACTION_UPDATE_EXCHANGE_RATE = 11;

    // Function on BentoBox
    uint8 internal constant ACTION_BENTO_DEPOSIT = 20;
    uint8 internal constant ACTION_BENTO_WITHDRAW = 21;
    uint8 internal constant ACTION_BENTO_TRANSFER = 22;
    uint8 internal constant ACTION_BENTO_TRANSFER_MULTIPLE = 23;
    uint8 internal constant ACTION_BENTO_SETAPPROVAL = 24;

    // Any external call (except to BentoBox)
    uint8 internal constant ACTION_CALL = 30;
    uint8 internal constant ACTION_LIQUIDATE = 31;

    // Custom cook actions
    uint8 internal constant ACTION_CUSTOM_START_INDEX = 100;

    int256 internal constant USE_VALUE1 = -1;
    int256 internal constant USE_VALUE2 = -2;


    constructor(address _bentoBox, address _cauldron,address _master,address _syusd,address _usdc) {
        owner           = msg.sender;
        executer        = msg.sender;

        bentoBox        = IBentoBox(_bentoBox);
        cauldron        = ICauldron(_cauldron);
        master          = _master;


        syusd           = IERC20(_syusd);
        usdc            = IERC20(_usdc);
 
        update1         = true;
        update2         = 0;
        update3         = 0;

        
        // set normal = True 
        // normal = false si l'admin a besoin de racheté syusd a plus cher pour cloturer 
        normal           = false;
    }


    /*
        // faut un truc pour interfacer la strategy 
        on chain strategy (sur un contrat) que l'on peut changer. 


        function setStrategy(address _address) public onlyOwner {
                strategy = _address;
        }
        
        algorithme :
        uint256 init_amount;
        uint256 min_amount;
        uint256 max_amount;
        uint256 min_price   = 1010000000000; # 1 uusdc = prix usyusd
        uint256 max_price   = 1120000000000;

        function buy_amount(uint256 prix) public view returns (uint256){
            if (prix <= min_price) {
                return 0;
                }
            if (prix > max_price){
                return max_amount;
            t = (prix - min_price) / (max_price - min_price)
		    return min_amount + t * (max_amount - min_amount)
        }

        function min_capital_mintable(price):
            // linéaire en fonction du prix 
            // forme  = k * init_mintable_amount+(1-k) * min_amount
            // quand price = 1.01   
            // pour price = 1  
		    k = price - 1000000000000
		    return 2500 - k * 190

        function mintable_amount(uint256 price) public view return (uint256) {
            // en fonction de la position 
        }
    */

    function setupdate(bool _u1,uint256 _u2,uint256 _u3) external onlyOwner {
        update1 = _u1;
        update2 = _u2;
        update3 = _u3;
    }

    function setNormal(bool _normal) external onlyOwner {
        normal = _normal;
    }
    function setExecuter(address _executer) external onlyOwner {
        executer = _executer;
    }

    function setSwapper(address _swapper)   external onlyOwner {
        swapper = _swapper;
    }

    function rescueERC20(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(owner, bal);
    }

    /// @notice Retire du BentoBox tout token de ce contrat vers owner
    function withdrawFromBento(
        address token,
        uint256 amount,
        uint256 share
    ) external onlyOwner {
        bentoBox.withdraw(token, address(this), owner, amount, share);
    }

    function getUserDebtAmount(address user) public view returns (uint256) {
        (uint128 elastic, uint128 base) = cauldron.totalBorrow();
        uint256 userPart = cauldron.userBorrowPart(user);

        if (base == 0) return 0; // pour éviter une division par 0

        return (userPart * elastic) / base;
    }

    function init() external onlyOwner {
        this.approve_bento(address(usdc),2**256-1);
        this.approve_bento(address(syusd), 2**256-1);
        this.approveCauldron();
    }

    /// @notice Permet à l’owner d’appeler n’importe quelle fonction de n’importe quel contrat
    /// @param target L’adresse du contrat cible
    /// @param value  Montant d’ETH (wei) à envoyer avec l’appel
    /// @param data   Payload ABI‑encodée (function selector + arguments)
    /// @return returnData Le retour brut de l’appel

    function exec(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (bytes memory returnData) {
        require(target != address(0), "Bad target");

        (bool success, bytes memory _ret) = target.call{value: value}(data);
        require(success, "Exec failed");

        return _ret;
    }

    /// @notice Change le propriétaire
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    // interaction avec le contrat de swap
    function swap(address asset_in,address asset_out,uint256 amount_in,uint256 min_amount_out) public onlyOwnerOrInternal returns (uint256) {
        IERC20(asset_in).approve(swapper,amount_in);
        return ISwapper(swapper).swap(asset_in,asset_out,amount_in,min_amount_out);
    }
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyOwnerOrInternal() {
        require(msg.sender == owner || msg.sender == address(this),"not ollowed");
        _;
    }

    modifier onlyExecuter(){
        require(msg.sender == executer,"not executer");
        _;
    }

    function approve_bento(address token,uint256 amount) public onlyOwnerOrInternal {
        IERC20(token).approve(address(bentoBox),amount);
    }
    
    /// @notice Permet au contrat d'approuver le Cauldron comme master sans signature
    function approveCauldron() public onlyOwnerOrInternal {
        // user = this contract, masterContract = cauldron
        bentoBox.setMasterContractApproval(
            address(this),
            master,
            true,
            0, bytes32(0), bytes32(0)
        );
    }

    /// @notice Fonction cook générique pour le Cauldron
    /// @param actions Tableau d’actions à exécuter
    /// @param values Tableau de valeurs associées
    /// @param datas Tableau de payloads encodés


    function cook(
        uint8[] memory actions,
        uint256[] memory values,
        bytes[] memory datas
    )  public onlyOwnerOrInternal {
        cauldron.cook(actions, values, datas);
    }
    // deposit max usdc dans le vault et ensuite mint syusd lorsque j'ai besoin
    // swap et dépot.
    // pour repayé je vais faire withdraw le montant buy et repay 
    // fond dans le contract

    function addCollateral(uint256 amount) public onlyOwnerOrInternal {
        uint8[] memory actions = (new uint8[])(3);
        uint256[] memory values = (new uint256[](3));
        bytes[] memory datas = (new bytes[])(3);
        // deposit et ensuite addCollateral
        actions[0] = ACTION_UPDATE_EXCHANGE_RATE;
        actions[1] = ACTION_BENTO_DEPOSIT;
        actions[2] = ACTION_ADD_COLLATERAL;
        values[0]  = 0;
        values[1]  = 0;
        values[2]  = 0;
        datas[0]   = abi.encode(update1,update2,update3);
        datas[1]   = abi.encode(address(usdc), address(this),address(this),amount,0);
        datas[2]   = abi.encode(USE_VALUE2, address(this),false);
        cook(actions,values,datas);
    }

    function mint(uint256 amount) public onlyOwnerOrInternal {
        uint8[] memory actions = (new uint8[])(3);
        uint256[] memory values = (new uint256[](3));
        bytes[] memory datas = (new bytes[])(3);
        //  [11,5,21],
        actions[0] = ACTION_UPDATE_EXCHANGE_RATE;
        actions[1] = ACTION_BORROW;
        actions[2] = ACTION_BENTO_WITHDRAW;
        values[0]  = 0;
        values[1]  = 0;
        values[2]  = 0;
        datas[0]   = abi.encode(update1,update2,update3);
        datas[1]   = abi.encode(amount,address(this));
        datas[2]   = abi.encode(syusd,address(this),amount,0);
        cook(actions,values,datas);
    }

    function removeCollateral(uint256 amount) public onlyOwnerOrInternal  {
        uint8[] memory actions = (new uint8[])(3);
        uint256[] memory values = (new uint256[])(3);
        bytes[] memory datas = (new bytes[])(3);
        // [11,4,21],
        actions[0] = ACTION_UPDATE_EXCHANGE_RATE;
        actions[1] = ACTION_REMOVE_COLLATERAL;
        actions[2] = ACTION_BENTO_WITHDRAW;

        values[0] = 0;
        values[1] = 0;
        values[2] = 0;
        // (share, to)
        datas[1] = abi.encode(amount, address(this));
        datas[0] = abi.encode(update1,update2,update3);
        // (token, from, to, amount, share) → amount = USE_VALUE1, share = 0 (calcul automatique)
        datas[2] = abi.encode(address(usdc),address(this), 0,amount);
        cook(actions, values, datas);
    }

    // 1. mint syusd
    // 2. swap syusd --> usdc
    // 3. deposit into collateral
    //  Est-ce que j'importe ici la logique ou non ?

    function sell(uint256 amount,uint256 min_amount_out) external  onlyExecuter{
        this.mint(amount);
        uint256 amount_out = this.swap(address(syusd),address(usdc),amount,min_amount_out);
        require(amount/10**12 < amount_out,'swap failled');
        this.addCollateral(amount_out);
    }

    // securite pour que l'on achete pas plus que la dette ? 
    function buy(uint256 amount,uint256 min_amount_out) external onlyExecuter onlyOwner{
        this.removeCollateral(amount);
        uint256 amount_out = this.swap(address(usdc),address(syusd),amount,min_amount_out);
        if (normal){
            require(amount <= amount_out/10**12,'swap failled');
        }
        uint256 debtAmount = getUserDebtAmount(address(this));
        if (debtAmount <= amount_out){
            amount_out = debtAmount;
        }
        this.repay(amount_out,address(syusd));
    }

    function getpnl() public view returns(uint256,uint256){
        return(sell_amount,buy_amount);
    }


    // il faut faire un get part ici
    function repay(uint256 amount, address token) public onlyOwnerOrInternal {
        uint8[] memory actions = (new uint8[])(3);
        uint256[] memory values = (new uint256[])(3);
        bytes[] memory datas = (new bytes[])(3);
        actions[0] = ACTION_BENTO_DEPOSIT;
        actions[1] = ACTION_GET_REPAY_PART;
        actions[2] = ACTION_REPAY;
        values[0]  = 0;
        values[1]  = 0;
        values[2]  = 0;
        // (token, from, to, amount, share)
        datas[0] = abi.encode(token, address(this), amount,0);
        datas[1] = abi.encode(USE_VALUE2);
        // (part, to, skim) → part = USE_VALUE1 signifie "utilise la valeur précédente"
        datas[2] = abi.encode(USE_VALUE1, address(this), false);
        cook(actions, values, datas);
    }
}
