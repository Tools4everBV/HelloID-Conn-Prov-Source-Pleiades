$config = ConvertFrom-Json $configuration;
$count = 0
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

# Récupération de tous les salariés connus de Pléiades
$queryStatmentPerson  = @"
SELECT
    salarie.matricule AS Matricule,
    salarie.nom_usuel AS Nom_usuel,
    salarie.nompatronymique AS Nom_patronymique,
    salarie.prenom1 AS Prenom,
    xsalinfosdivers.coderpps AS RPPS,
    xsalinfosdivers.codeadeli AS ADELI
FROM ng_mod.salarie
LEFT JOIN ng_mod.xsalinfosdivers ON xsalinfosdivers.salarie = salarie.oid
"@

# Récupération du dernier manager de chaque salarié
$queryStatmentManager  = @"
SELECT 
  Matricule_Collaborateur,
  Matricule_Manager
FROM (
  SELECT
    --TO_CHAR(XRCMANAGER.BEGIN_DATE, 'DD/MM/YYYY') AS Début,
    --TO_CHAR(XRCMANAGER.END_DATE, 'DD/MM/YYYY') AS Fin,
    Collaborateur.Matricule AS Matricule_Collaborateur,
    --Collaborateur.Nom_usuel AS Collaborateur,
    Manager.Matricule AS Matricule_Manager,
    --Manager.Nom_usuel AS Manager,
    ROW_NUMBER() OVER (PARTITION BY Collaborateur.Nom_usuel ORDER BY XRCMANAGER.END_DATE DESC) AS rn
  FROM
    ng_mod.XRCMANAGER,
    ng_mod.RELATIONCONTRAT,
    ng_mod.SALARIE Collaborateur,
    ng_mod.SALARIE Manager
  WHERE
    RELATIONCONTRAT.OID = XRCMANAGER.RELATIONCONTRAT
    AND Collaborateur.OID = RELATIONCONTRAT.RELATMATRICULE
    AND Manager.OID = XRCMANAGER.SALARIE
) 
WHERE rn = 1
"@

# Récupération des affectations de chaque salarié
$queryStatmentContract  = @"
SELECT
    salarie.matricule AS Matricule,
    to_char(relationcontrat.relatdatedeb, 'DD/MM/YYYY') AS Debut_Rel,
    to_char(relationcontrat.relatdatefin, 'DD/MM/YYYY') AS Fin_Rel,
    ta_contrattype.contrattypecode AS Type_contrat,
    xrcaffectuf.oid AS Affectation_Id,
    xrcaffectuf.ufprincipale AS Affectation_Principale,
    to_char(xrcaffectuf.dteffet, 'MM-DD-YYYY') AS Debut_Aff,
    CASE
        WHEN xrcaffectuf.dtfin = to_date('01/01/2999', 'MM-DD-YYYY') THEN to_char(contrat.ctrdatefinreel, 'MM-DD-YYYY') -- Forcer la fin d'une affectation, ou la positionner à NULL, selon l'état du contrat, si elle n'est pas renseignée
        ELSE to_char(xrcaffectuf.dtfin, 'MM-DD-YYYY') 
    END AS Fin_Aff,
    xunitefct.CODE AS Code_UF,
    xunitefct.LIBLONG AS Libelle_UF,
    ta_emploi.emploicode AS Code_Emploi,
    ta_emploi.emploilibelle AS Libelle_Emploi,
    xta_metier.code AS Code_Metier,
    xta_metier.LIBLONG AS Libelle_Metier,
    xta_regrmetier.code AS Code_Regroupement,
    xta_regrmetier.LIBLONG AS Libelle_Regroupement,
    familleprof.filierecode AS Code_Filiere,
    familleprof.libelle AS Libelle_Filiere,
    xta_metier.mednonmed AS is_Medical

FROM ng_mod.salarie

INNER JOIN ng_mod.relationcontrat   ON salarie.oid = relationcontrat.relatmatricule AND (relationcontrat.relatdatefin IS NULL OR relationcontrat.relatdatefin >= to_date('$($config.ReferenceDate)')) -- Filtre les anciens contrats

INNER JOIN ng_mod.xrcaffectuf       ON relationcontrat.oid = xrcaffectuf.relationcontrat AND (xrcaffectuf.dtfin = to_date('01/01/2999') OR xrcaffectuf.dtfin >= to_date('$($config.ReferenceDate)')) -- Filtre les anciennes affectations
LEFT JOIN ng_mod.xunitefct         ON xrcaffectuf.xunitefct = xunitefct.oid

LEFT JOIN ng_mod.contrat            ON relationcontrat.oid = contrat.ctrrelation
LEFT JOIN ng_mod.typejuridqctr      ON contrat.oid = typejuridqctr.typecontrat AND (typejuridqctr.begin_date <= xrcaffectuf.dteffet AND typejuridqctr.end_date >= xrcaffectuf.dteffet) -- Filtre les natures de contrats sur les affectations en cours
LEFT JOIN ng_mod.ta_contrattype     ON typejuridqctr.typejuridique = ta_contrattype.oid

-- Selection de l'emploi le plus recent sur l'affectation en cours
LEFT JOIN (
        SELECT e.*,ROW_NUMBER() OVER(PARTITION BY e.emploirelation ORDER BY e.end_date DESC) AS rn
        FROM ng_mod.emploi e
        ) emploi  
    ON relationcontrat.oid = emploi.emploirelation AND emploi.rn = 1

LEFT JOIN ng_mod.ta_emploi          ON emploi.emploi = ta_emploi.oid
LEFT JOIN ng_mod.xta_metier         ON emploi.xta_metier = xta_metier.oid
LEFT JOIN ng_mod.xta_regrmetier     ON xta_metier.xta_regrmetier = xta_regrmetier.oid
LEFT JOIN ng_mod.familleprof        ON emploi.xfiliere = familleprof.oid
"@  

 try {
     ### open up oracle connection to database ###
    $con = [Oracle.ManagedDataAccess.Client.OracleConnection]::new($connectionString)
    $con.Open()
    
     ### create object ###
    $cmd = $con.CreateCommand()
    $cmd.CommandType = [System.Data.CommandType]::Text
    
     ### create person datatable and load results into datatable ###
    $cmd.CommandText = $queryStatmentPerson
    $dataTablePerson = [System.Data.DataTable]::new()
    $dataTablePerson.Load($cmd.ExecuteReader())
    #Write-Information ($dataTablePerson | ConvertTo-Json)
    
     ### create contract datatable and load results into datatable ###
    $cmd.CommandText = $queryStatmentManager
    $dataTableManager = [System.Data.DataTable]::new()
    $dataTableManager.Load($cmd.ExecuteReader())
    #Write-Information ($dataTableManager | ConvertTo-Json)
    
     ### create contract datatable and load results into datatable ###
    $cmd.CommandText = $queryStatmentContract
    $dataTableContract = [System.Data.DataTable]::new()
    $dataTableContract.Load($cmd.ExecuteReader())
    #Write-Information ($dataTableContract | ConvertTo-Json)

    $DataTableContractGrouped = $DataTableContract  | Group-Object -Property "Matricule" -AsHashTable -AsString
    #Write-Information ($DataTableContractGrouped | ConvertTo-Json)

    $DataTableManagerGrouped = $DataTableManager  | Group-Object -Property "Matricule_Collaborateur" -AsHashTable -AsString
    #Write-Information ($DataTableManagerGrouped["60070"].Matricule_Manager | ConvertTo-Json)
 }
 catch {
    Write-Error "Error while retrieving data! $_."
 }
finally
{
    if ($OracleConnection.State -eq ‘Open’) { $OracleConnection.close() }
}
 
foreach($p in $dataTablePerson)
{
    $person = @{}
    $person['ExternalId'] = $p.Matricule
    $person['DisplayName'] = "$($p.Nom_usuel) $($p.Prenom) $($p.Matricule)"
    $person['GivenName'] = "$($p.Prenom)"
    $person['LastName'] = "$($p.Nom_usuel)"
    $person['LastNameBirth'] = "$($p.Nom_patronymique)"
    $person['RPPS'] = $p.RPPS
    $person['ADELI'] = $p.ADELI

    $person['Contracts'] = [System.Collections.ArrayList]@()
    
    foreach($c in $DataTableContractGrouped["$($p.Matricule)"])
    {
        $contract = @{};
        $contract["Type_contrat"] = $c.Type_contrat
        $contract["Debut_Rel"] = $c.Debut_Rel
        $contract["Fin_Rel"] = $c.Fin_Rel
        $contract["Id"] = $c.Affectation_Id
        $contract["Affectation_Principale"] = $c.Affectation_Principale #if($c.Affectation_Principale -eq '1'){$true} else{$false}
        $contract["Debut_Aff"] = $c.Debut_Aff
        $contract["Fin_Aff"] = $c.Fin_Aff
        $contract["Code_UF"] = $c.Code_UF
        $contract["Libelle_UF"] = $c.Libelle_UF
        $contract["Manager_ExternalId"] = $DataTableManagerGrouped["$($p.Matricule)"].Matricule_Manager
        $contract["Code_Emploi"] = $c.Code_Emploi
        $contract["Libelle_Emploi"] = $c.Libelle_Emploi
        $contract["Code_Metier"] = $c.Code_Metier
        $contract["Libelle_Metier"] = $c.Libelle_Metier
        $contract["Code_Regroupement"] = $c.Code_Regroupement
        $contract["Libelle_Regroupement"] = $c.Libelle_Regroupement
        $contract["Code_Filiere"] = $c.Code_Filiere
        $contract["Libelle_Filiere"] = $c.Libelle_Filiere
        $contract["is_Medical"] = if($c.is_Medical -eq 'M'){$true} else{$false}

        [void]$person.Contracts.Add($contract)
    }

    if ($person.Contracts)
    {
        Write-Output ($person | ConvertTo-Json)
        $count += 1
    }
}

Write-Information "Finished Processing Persons ($count)"
