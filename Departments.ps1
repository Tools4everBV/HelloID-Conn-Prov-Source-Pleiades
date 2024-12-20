$config = ConvertFrom-Json $configuration;

Add-Type -Path $config.DLLPath

 ### connection string ###
$dataSource = @"
(DESCRIPTION =
    (LOAD_BALANCE = yes)
    (FAILOVER = yes)
    (ADDRESS =
        (PROTOCOL = TCP)
        (HOST = $($config.Host))
        (PORT = $($config.Port))
    )
    (CONNECT_DATA =
        (SERVICE_NAME = $($config.ServiceName))
        (FAILOVER_MODE =
            (TYPE = SELECT)
            (METHOD = BASIC)
            (RETRIES = 300)
            (DELAY = 2)
        )
    )
)
"@

$connectionString = "User Id=$($config.username);Password=$($config.password);Data Source=$dataSource"

$queryStatmentUF  = @'
SELECT
    xunitefct.code AS Code_UF,
    xunitefct.liblong AS Libelle_UF
FROM ng_mod.xunitefct
WHERE NOT REGEXP_LIKE(xunitefct.liblong, '^ *\*')
ORDER BY xunitefct.code
'@  

 try {
     ### open up oracle connection to database ###
    $con = [Oracle.ManagedDataAccess.Client.OracleConnection]::new($connectionString)
    $con.Open()
    
     ### create object ###
    $cmd = $con.CreateCommand()
    $cmd.CommandType = [System.Data.CommandType]::Text
    
     ### create person datatable and load results into datatable ###
    $cmd.CommandText = $queryStatmentUF
    $dataTable = [System.Data.DataTable]::new()
    $dataTable.Load($cmd.ExecuteReader())
    #Write-Information ($dataTable | ConvertTo-Json)

 }
 catch {
    Write-Error "Error while retrieving data! $_."
 }
finally
{
    if ($OracleConnection.State -eq ‘Open’) { $OracleConnection.close() }
}
 
$Count = 0
foreach($uf in $dataTable)
{
    $uniteFonctionnelle = @{}
    $uniteFonctionnelle['ExternalId'] = $uf.Code_UF
    $uniteFonctionnelle['DisplayName'] = $uf.Libelle_UF
    $uniteFonctionnelle['Name'] = $uf.Libelle_UF
    $Count += 1

    Write-Output ($uniteFonctionnelle | ConvertTo-Json)
}

Write-Information "Finished Processing UF ($Count)"